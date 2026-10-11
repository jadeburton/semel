// Card.swift
// SemelMonitor
//
// One notification: what one settle did, as the events said it. A card holds the typed
// values it was made from — paths, records, counts — and `CardText` draws its lines, so
// the panel, `--print` and a test read the same words from one place.

import SemelProtocol

/// What a settle's `settled` event counted, the part a card shows: how many nodes ran and
/// how many were answered from the cache.
public struct SettleCounts: Equatable, Sendable {
    public let computed:  Int
    public let fromCache: Int

    public init(computed: Int, fromCache: Int) {
        self.computed  = computed
        self.fromCache = fromCache
    }
}

public struct Card: Equatable, Sendable {

    /// A result is something to know and goes by itself; an error is something to act on
    /// and stays until it is clicked or a later settle gives its products a value.
    public enum Kind: Equatable, Sendable {
        case result
        case errors
    }

    public enum Content: Equatable, Sendable {
        /// What the settle's `artifacts` said, each list in the event's path order, and the
        /// `settled` before it — nil for a settle that scheduled nothing and still moved a
        /// product, a removal's.
        case result(changed: [String], appeared: [String], disappeared: [String], counts: SettleCounts?)
        /// The new failures the settle's `errors` event carried, as the report reads them.
        case errors(records: [ErrorRecord])
    }

    /// Unique within one planner, in the order cards were made.
    public let id: Int
    public let content: Content
    /// How many older cards were folded into this one because more than the stack holds
    /// were on screen: the bottom card's `and N earlier`.
    public internal(set) var earlier: Int

    public init(id: Int, content: Content, earlier: Int = 0) {
        self.id      = id
        self.content = content
        self.earlier = earlier
    }

    public var kind: Kind {
        switch content {
        case .result: return .result
        case .errors: return .errors
        }
    }

    /// The products the card names, in the order it names them: for a result, what
    /// changed, then what appeared, then what disappeared; for errors, the products
    /// without a value in path order, a tree product once by its folder.
    public var products: [StoppedProduct] {
        switch content {
        case .result(let changed, let appeared, let disappeared, _):
            return (changed + appeared + disappeared).map { StoppedProduct(path: $0) }
        case .errors(let records):
            var seen: Set<String> = []
            return records
                .flatMap(\.products)
                .map { $0.treeFolder.map { StoppedProduct(path: $0, treeFolder: $0) } ?? $0 }
                .sorted { $0.path < $1.path }
                .filter { seen.insert($0.path).inserted }
        }
    }
}

/// What became of the cards on screen after the planner was told something: what a panel
/// stack applies and what `--print` writes.
public enum CardChange: Equatable, Sendable {
    /// A new card, on top.
    case shown(Card)
    /// A card gone: its eight seconds over, clicked, or replaced by a settle that gave its
    /// products a value.
    case dismissed(Card)
    /// A card pushed off the bottom of a full stack, counted in the next one's `earlier`.
    case folded(Card)
    /// A card on screen whose `earlier` count moved.
    case updated(Card)
}
