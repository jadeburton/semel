// NotificationPlanner.swift
// SemelMonitor
//
// Events in, cards out. The planner decides everything a card shows and when it goes; the
// panels and `--print` only draw what it hands them. It is not thread-safe: the monitor
// calls it on the main queue, a test on its own thread.

import SemelCLI
import SemelNodeKit
import SemelProtocol

public final class NotificationPlanner {

    /// How long a result card stays when the pointer is not over it.
    public static let resultLifetime = Duration.seconds(8)

    /// How many cards are on screen at most; older ones fold into the bottom one.
    public static let mostCardsShown = 5

    /// How long a running card waits, after its settle's `settled`, for the `artifacts`
    /// that would make it the result. The engine sends the two back to back when a product
    /// moved and sends no `artifacts` when none did, and nothing else marks a settle's end:
    /// a running card left standing until the next settle would say `Building` over a
    /// quiet engine. Should the event come later than this, it makes a card of its own.
    public static let artifactsWait = Duration.seconds(1)

    /// On screen, newest first.
    public private(set) var cards: [Card] = []

    /// Whether new cards are swallowed. Errors still replace and expiry still runs: a
    /// pause silences what is coming, it does not freeze what is there.
    public private(set) var isPaused = false

    /// The card the last settle that made one made, shown or not: the status item's
    /// `last settle:` line, and what *Resume* shows. Never a running card.
    public private(set) var lastCard: Card?

    /// Where the settle in progress stands, from its latest `progress`; nil between
    /// settles. The status item's settling state, kept whether or not a running card shows
    /// it: a pause, or a running card clicked away, silences the card and not the state.
    public private(set) var settleInProgress: ProgressRecord?

    /// Whether an error card is held: on screen, or made during a pause and still news —
    /// what turns the status item's glyph red.
    public var holdsErrorCard: Bool {
        cards.contains { $0.kind == .errors } || (lastCardSwallowed && lastCard?.kind == .errors)
    }

    private let clock: any Clock
    private let only: [String]
    private var nextID = 1

    /// When each result card on screen goes, unless the pointer is over it.
    private var deadlines: [Int: Duration] = [:]
    private var hovered: Set<Int> = []

    /// What each error card on screen waits on: the keys of its products still without a
    /// value. A key is a product's path, or a tree's folder with a separator.
    private var awaited: [Int: Set<String>] = [:]

    /// Whether `lastCard` came while paused and has not been shown.
    private var lastCardSwallowed = false

    // MARK: - The running card

    /// The running card on screen, if any.
    private var runningCardID: Int?
    /// When a running card whose settle has ended goes, should no `artifacts` come for it.
    private var runningCardWaitsUntil: Duration?
    /// The settle in progress had its running card clicked away, so its next `progress`
    /// does not bring it back.
    private var runningCardDeclined = false

    // MARK: - The settle being read

    /// The engine sends one settle as `progress` while it runs, then `errors` (when it
    /// found new failures), `settled` (when it scheduled anything) and `artifacts` (when a
    /// product moved), in that order, each only when it has something to say — the order
    /// `CommandInterpreter` prints them in. So the card cannot wait for all three: an error
    /// settle's card is made at `settled` and the `artifacts` after it only replaces, a
    /// result card is made at `artifacts`, and the first event of the next settle closes
    /// whatever is held.
    private var heldErrors: [ErrorRecord] = []
    private var heldCounts: SettleCounts?
    private var heldSettleMadeItsCard = false

    /// `only` is `--only`: folders of `output:`, as `App`, `App/` or `output:/App`. Empty
    /// keeps every product.
    public init(clock: any Clock, only: [String] = []) {
        self.clock = clock
        self.only  = only.map(Self.prefix(ofFolder:))
    }

    // MARK: - Events

    @discardableResult
    public func receive(_ event: DaemonEvent) -> [CardChange] {
        var changes = expire()
        switch event {
        case .progress(let record):
            // Progress comes before a settle's other events, so one now belongs to a
            // settle that has not ended: whatever an earlier settle left held is closed.
            changes += closeHeldSettle()
            settleInProgress = record
            changes += showProgress(record)
        case .errors(let records, _):
            if heldCounts != nil {
                changes += closeHeldSettle()
            }
            heldErrors += records
        case .settled(_, let computed, let fromCache, let errors):
            if heldCounts != nil {
                changes += closeHeldSettle()
            }
            heldCounts          = SettleCounts(computed: computed, fromCache: fromCache)
            settleInProgress    = nil
            runningCardDeclined = false
            // A graph that holds no error leaves no error card standing.
            if errors == 0 {
                changes += replaceErrorCards { _ in true }
            }
            if !heldErrors.isEmpty {
                changes += makeErrorCard()
                heldSettleMadeItsCard = true
                changes += retireRunningCard()
            } else if runningCardID != nil {
                runningCardWaitsUntil = clock.now + Self.artifactsWait
            }
        case .artifacts(let appeared, let changed, let disappeared, let treeFolders):
            changes += replaceErrorCards(givenAValue: appeared + changed)
            if !heldSettleMadeItsCard {
                if heldErrors.isEmpty {
                    changes += makeResultCard(changed: changed, appeared: appeared, disappeared: disappeared,
                                              treeFolders: treeFolders)
                } else {
                    changes += makeErrorCard()
                }
            }
            // A running card the settle's products did not resolve — `--only` kept none
            // of them — has nothing left to say.
            changes += retireRunningCard()
            settleInProgress = nil
            resetHeldSettle()
        case .notice:
            break
        }
        return changes
    }

    /// The connection is gone: whatever settle was being read will never finish, and its
    /// running card goes with it.
    @discardableResult
    public func engineLost() -> [CardChange] {
        resetHeldSettle()
        settleInProgress    = nil
        runningCardDeclined = false
        return retireRunningCard()
    }

    // MARK: - The person

    /// *Pause notifications*.
    public func pause() {
        isPaused = true
    }

    /// *Resume*: the last settle's card, when it came during the pause and is still news.
    @discardableResult
    public func resume() -> [CardChange] {
        isPaused = false
        guard lastCardSwallowed, let card = lastCard else {
            return expire()
        }
        lastCardSwallowed = false
        return expire() + show(card)
    }

    /// A click. A running card clicked away stays away for the rest of its settle, whose
    /// result still makes a card of its own.
    @discardableResult
    public func dismiss(cardID: Int) -> [CardChange] {
        if cardID == runningCardID, settleInProgress != nil {
            runningCardDeclined = true
        }
        return expire() + (remove(cardID).map { [.dismissed($0)] } ?? [])
    }

    /// The pointer over a card holds its expiry; leaving gives it its full time again.
    public func pointerEntered(cardID: Int) {
        hovered.insert(cardID)
    }

    @discardableResult
    public func pointerLeft(cardID: Int) -> [CardChange] {
        hovered.remove(cardID)
        if deadlines[cardID] != nil {
            deadlines[cardID] = clock.now + Self.resultLifetime
        }
        return expire()
    }

    // MARK: - Time

    /// When the planner next has something to do — a result card to go, or a running card
    /// whose settle has ended — for the caller to come back then with `advance`.
    public var nextDeadline: Duration? {
        (Array(deadlines.filter { !hovered.contains($0.key) }.values) + [runningCardWaitsUntil].compactMap { $0 })
            .min()
    }

    /// The result cards whose time is up, dismissed; the running card gone when its settle
    /// ended with no product moved.
    @discardableResult
    public func advance() -> [CardChange] {
        expire()
    }

    private func expire() -> [CardChange] {
        let now = clock.now
        let due = deadlines.filter { !hovered.contains($0.key) && $0.value <= now }.keys.sorted()
        var changes: [CardChange] = due.compactMap { remove($0) }.map { .dismissed($0) }
        if let waitsUntil = runningCardWaitsUntil, waitsUntil <= now {
            changes += retireRunningCard()
        }
        return changes
    }

    // MARK: - The running card

    /// The running card made by the first `progress` that lists a running node, and
    /// redrawn in place by every one after it. A settle whose records list nothing running
    /// shows no card, and neither does one under a pause or whose card was clicked away.
    /// The card lists what the record lists in the record's order, which is the order the
    /// nodes started, and nothing moves on the clock: a line changes only when a node
    /// starts or finishes, so a node that stays on the card is the same node.
    private func showProgress(_ record: ProgressRecord) -> [CardChange] {
        if let runningID = runningCardID, let index = cards.firstIndex(where: { $0.id == runningID }) {
            guard case .running(let shown) = cards[index].content, shown != record else {
                return []
            }
            cards[index] = Card(id: runningID, content: .running(record: record), earlier: cards[index].earlier)
            return [.progressed(cards[index])]
        }
        guard !record.running.isEmpty, !isPaused, !runningCardDeclined else {
            return []
        }
        let card = Card(id: takeID(), content: .running(record: record))
        runningCardID = card.id
        return show(card)
    }

    /// The running card goes with nothing in its place.
    private func retireRunningCard() -> [CardChange] {
        guard let runningID = runningCardID else {
            return []
        }
        return remove(runningID).map { [.dismissed($0)] } ?? []
    }

    // MARK: - Making cards

    private func makeResultCard(changed: [String], appeared: [String], disappeared: [String],
                                treeFolders: [String: String]) -> [CardChange] {
        let changed     = changed.filter { isKept($0, treeFolders: treeFolders) }
        let appeared    = appeared.filter { isKept($0, treeFolders: treeFolders) }
        let disappeared = disappeared.filter { isKept($0, treeFolders: treeFolders) }
        guard !(changed.isEmpty && appeared.isEmpty && disappeared.isEmpty) else {
            return []
        }
        let keptPaths = Set(changed + appeared + disappeared)
        let kept      = treeFolders.filter { keptPaths.contains($0.key) }
        return offer(.result(changed: changed, appeared: appeared, disappeared: disappeared, counts: heldCounts,
                             treeFolders: kept))
    }

    private func makeErrorCard() -> [CardChange] {
        let records = only.isEmpty ? heldErrors : heldErrors.compactMap(keptPart)
        heldErrors = []
        guard !records.isEmpty else {
            return []
        }
        return offer(.errors(records: records))
    }

    /// A settle's card: in the running card's place when one is on screen, otherwise new on
    /// top; or swallowed by a pause and kept for *Resume*.
    private func offer(_ content: Card.Content) -> [CardChange] {
        if lastCardSwallowed, let swallowed = lastCard {
            awaited[swallowed.id] = nil
        }
        guard !isPaused else {
            let card = Card(id: takeID(), content: content)
            lastCard = card
            // An error card waits for its products while swallowed, so that one fixed
            // during the pause is not shown by *Resume*.
            if card.kind == .errors {
                awaited[card.id] = Self.keys(of: card)
            }
            lastCardSwallowed = true
            return retireRunningCard()
        }
        lastCardSwallowed = false
        if let runningID = runningCardID, let index = cards.firstIndex(where: { $0.id == runningID }) {
            clearRunningCard()
            let card = Card(id: runningID, content: content, earlier: cards[index].earlier)
            cards[index] = card
            lastCard     = card
            arm(card)
            return [.resolved(card)]
        }
        let card = Card(id: takeID(), content: content)
        lastCard = card
        return show(card)
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// On top; a sixth folds the oldest into the one above it.
    private func show(_ card: Card) -> [CardChange] {
        var changes: [CardChange] = [.shown(card)]
        cards.insert(card, at: 0)
        arm(card)
        while cards.count > Self.mostCardsShown, let oldest = remove(cards[cards.count - 1].id) {
            changes.append(.folded(oldest))
            let bottom = cards.count - 1
            cards[bottom].earlier += oldest.earlier + 1
            changes.append(.updated(cards[bottom]))
        }
        return changes
    }

    /// What a card on screen waits for: a result its eight seconds, an error its products.
    private func arm(_ card: Card) {
        switch card.kind {
        case .result:
            deadlines[card.id] = clock.now + Self.resultLifetime
        case .errors where awaited[card.id] == nil:
            awaited[card.id] = Self.keys(of: card)
        case .errors, .running:
            break
        }
    }

    private func remove(_ cardID: Int) -> Card? {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else {
            return nil
        }
        deadlines[cardID] = nil
        awaited[cardID]   = nil
        hovered.remove(cardID)
        if cardID == runningCardID {
            clearRunningCard()
        }
        return cards.remove(at: index)
    }

    private func clearRunningCard() {
        runningCardID         = nil
        runningCardWaitsUntil = nil
    }

    // MARK: - Replacing error cards

    /// Error cards whose every product now has a value go, as does a swallowed one: a
    /// failure fixed during a pause is not news after it.
    private func replaceErrorCards(givenAValue named: [String]) -> [CardChange] {
        guard !named.isEmpty else {
            return []
        }
        // A card for errors no product needs has nothing to wait on; only a settle that
        // leaves the graph without errors replaces it.
        var emptied: Set<Int> = []
        for (cardID, keys) in awaited where !keys.isEmpty {
            let remaining = keys.filter { key in !named.contains { Self.path($0, isNamedBy: key) } }
            awaited[cardID] = remaining
            if remaining.isEmpty {
                emptied.insert(cardID)
            }
        }
        return replaceErrorCards { emptied.contains($0) }
    }

    private func replaceErrorCards(where isReplaced: (Int) -> Bool) -> [CardChange] {
        if lastCardSwallowed, let card = lastCard, card.kind == .errors, isReplaced(card.id) {
            lastCardSwallowed = false
            awaited[card.id]  = nil
        }
        let replaced = cards.filter { $0.kind == .errors && isReplaced($0.id) }.map(\.id)
        return replaced.compactMap { remove($0) }.map { .dismissed($0) }
    }

    // MARK: - The settle

    /// Shows the errors an earlier settle held without a card, and retires a running card
    /// still waiting for the `artifacts` its settle did not send.
    private func closeHeldSettle() -> [CardChange] {
        defer { resetHeldSettle() }
        var changes: [CardChange] = []
        if !heldSettleMadeItsCard, !heldErrors.isEmpty {
            changes += makeErrorCard()
        }
        if runningCardWaitsUntil != nil {
            changes += retireRunningCard()
        }
        return changes
    }

    private func resetHeldSettle() {
        heldErrors = []
        heldCounts = nil
        heldSettleMadeItsCard = false
    }

    // MARK: - --only

    /// `output:/App/` for `App`, `App/` or `output:/App`.
    static func prefix(ofFolder folder: String) -> String {
        let root = "\(FileSystemName.output)/"
        var trimmed = folder.hasPrefix(root) ? String(folder.dropFirst(root.count)) : folder
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        while trimmed.hasPrefix("/") {
            trimmed.removeFirst()
        }
        return root + trimmed + "/"
    }

    /// Whether `--only` keeps the product at `path`: a tree's entry by its folder, as an
    /// error's product is kept.
    private func isKept(_ path: String, treeFolders: [String: String] = [:]) -> Bool {
        let named = treeFolders[path].map { "\($0)/" } ?? path
        return only.isEmpty || only.contains { named.hasPrefix($0) }
    }

    /// A record narrowed to the products `--only` keeps, or nil when it keeps none.
    private func keptPart(of record: ErrorRecord) -> ErrorRecord? {
        let products = record.products.filter { isKept($0.treeFolder.map { "\($0)/" } ?? $0.path) }
        guard !products.isEmpty else {
            return nil
        }
        return ErrorRecord(document: record.document, products: products, facts: record.facts)
    }

    /// The products an error card waits on, as the report keys them.
    private static func keys(of card: Card) -> Set<String> {
        Set(card.products.map { ProductNames.key(of: $0) })
    }

    /// Whether a product that moved, at `path`, is the one a key names: the product
    /// itself, or an entry of the tree whose folder the key is.
    static func path(_ path: String, isNamedBy key: String) -> Bool {
        key.hasSuffix("/") ? path.hasPrefix(key) : path == key
    }
}
