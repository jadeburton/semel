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

    /// On screen, newest first.
    public private(set) var cards: [Card] = []

    /// Whether new cards are swallowed. Errors still replace and expiry still runs: a
    /// pause silences what is coming, it does not freeze what is there.
    public private(set) var isPaused = false

    /// The card the last settle that made one made, shown or not: the status item's
    /// `last settle:` line, and what *Resume* shows.
    public private(set) var lastCard: Card?

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

    // MARK: - The settle being read

    /// The engine sends one settle as `errors` (when it found new failures), `settled`
    /// (when it scheduled anything) and `artifacts` (when a product moved), in that order,
    /// each only when it has something to say — the order `CommandInterpreter` prints
    /// them in. So the card cannot wait for all three: an error settle's card is made at
    /// `settled` and the `artifacts` after it only replaces, a result card is made at
    /// `artifacts`, and the first event of the next settle closes whatever is held.
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
        case .progress:
            // Progress comes before a settle's other events, so one now begins a settle.
            changes += closeHeldSettle()
        case .errors(let records):
            if heldCounts != nil {
                changes += closeHeldSettle()
            }
            heldErrors += records
        case .settled(_, let computed, let fromCache, let errors):
            if heldCounts != nil {
                changes += closeHeldSettle()
            }
            heldCounts = SettleCounts(computed: computed, fromCache: fromCache)
            // A graph that holds no error leaves no error card standing.
            if errors == 0 {
                changes += replaceErrorCards { _ in true }
            }
            if !heldErrors.isEmpty {
                changes += makeErrorCard()
                heldSettleMadeItsCard = true
            }
        case .artifacts(let appeared, let changed, let disappeared):
            changes += replaceErrorCards(givenAValue: appeared + changed)
            if !heldSettleMadeItsCard {
                if heldErrors.isEmpty {
                    changes += makeResultCard(changed: changed, appeared: appeared, disappeared: disappeared)
                } else {
                    changes += makeErrorCard()
                }
            }
            resetHeldSettle()
        case .notice:
            break
        }
        return changes
    }

    /// The connection is gone: whatever settle was being read will never finish.
    public func engineLost() {
        resetHeldSettle()
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

    /// A click.
    @discardableResult
    public func dismiss(cardID: Int) -> [CardChange] {
        expire() + (remove(cardID).map { [.dismissed($0)] } ?? [])
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

    /// When the next result card goes, for the caller to come back then with `advance`.
    public var nextDeadline: Duration? {
        deadlines.filter { !hovered.contains($0.key) }.values.min()
    }

    /// The result cards whose time is up, dismissed.
    @discardableResult
    public func advance() -> [CardChange] {
        expire()
    }

    private func expire() -> [CardChange] {
        let now = clock.now
        let due = deadlines.filter { !hovered.contains($0.key) && $0.value <= now }.keys.sorted()
        return due.compactMap { remove($0) }.map { .dismissed($0) }
    }

    // MARK: - Making cards

    private func makeResultCard(changed: [String], appeared: [String], disappeared: [String]) -> [CardChange] {
        let changed     = changed.filter(isKept)
        let appeared    = appeared.filter(isKept)
        let disappeared = disappeared.filter(isKept)
        guard !(changed.isEmpty && appeared.isEmpty && disappeared.isEmpty) else {
            return []
        }
        return offer(.result(changed: changed, appeared: appeared, disappeared: disappeared, counts: heldCounts))
    }

    private func makeErrorCard() -> [CardChange] {
        let records = only.isEmpty ? heldErrors : heldErrors.compactMap(keptPart)
        heldErrors = []
        guard !records.isEmpty else {
            return []
        }
        return offer(.errors(records: records))
    }

    /// A new card: shown, or swallowed by a pause and kept for *Resume*.
    private func offer(_ content: Card.Content) -> [CardChange] {
        let card = Card(id: nextID, content: content)
        nextID += 1
        if lastCardSwallowed, let swallowed = lastCard {
            awaited[swallowed.id] = nil
        }
        lastCard = card
        guard !isPaused else {
            // An error card waits for its products while swallowed, so that one fixed
            // during the pause is not shown by *Resume*.
            if card.kind == .errors {
                awaited[card.id] = Self.keys(of: card)
            }
            lastCardSwallowed = true
            return []
        }
        lastCardSwallowed = false
        return show(card)
    }

    /// On top; a sixth folds the oldest into the one above it.
    private func show(_ card: Card) -> [CardChange] {
        var changes: [CardChange] = [.shown(card)]
        cards.insert(card, at: 0)
        switch card.kind {
        case .result:
            deadlines[card.id] = clock.now + Self.resultLifetime
        case .errors where awaited[card.id] == nil:
            awaited[card.id] = Self.keys(of: card)
        case .errors:
            break
        }
        while cards.count > Self.mostCardsShown, let oldest = remove(cards[cards.count - 1].id) {
            changes.append(.folded(oldest))
            let bottom = cards.count - 1
            cards[bottom].earlier += oldest.earlier + 1
            changes.append(.updated(cards[bottom]))
        }
        return changes
    }

    private func remove(_ cardID: Int) -> Card? {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else {
            return nil
        }
        deadlines[cardID] = nil
        awaited[cardID]   = nil
        hovered.remove(cardID)
        return cards.remove(at: index)
    }

    // MARK: - Replacing error cards

    /// Error cards whose every product now has a value go, as does a swallowed one: a
    /// failure fixed during a pause is not news after it.
    private func replaceErrorCards(givenAValue paths: [String]) -> [CardChange] {
        guard !paths.isEmpty else {
            return []
        }
        // A card for errors no product needs has nothing to wait on; only a settle that
        // leaves the graph without errors replaces it.
        var emptied: Set<Int> = []
        for (cardID, keys) in awaited where !keys.isEmpty {
            let remaining = keys.filter { key in !paths.contains { Self.path($0, isNamedBy: key) } }
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

    private func closeHeldSettle() -> [CardChange] {
        defer { resetHeldSettle() }
        guard !heldSettleMadeItsCard, !heldErrors.isEmpty else {
            return []
        }
        return makeErrorCard()
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

    private func isKept(_ path: String) -> Bool {
        only.isEmpty || only.contains { path.hasPrefix($0) }
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
