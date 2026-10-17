// Card.swift
// SemelMonitor
//
// One notification: what one settle did, as the events said it, or where a settle still
// going stands. A card holds the typed values it was made from — paths, records, counts —
// and `CardText` draws its lines, so the panel, `--print` and a test read the same words
// from one place.

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
    /// and stays until it is clicked or a later settle gives its products a value. A running
    /// card is a settle still going, and becomes the settle's result or errors in its place.
    public enum Kind: Equatable, Sendable {
        case running
        case result
        case errors
    }

    public enum Content: Equatable, Sendable {
        /// A settle in progress, as its latest `progress` record says: every running node a
        /// line, in the record's order, so a node keeps its line while it runs.
        case running(record: ProgressRecord)
        /// What the settle's `artifacts` said, each list in the event's path order, and the
        /// `settled` before it — nil for a settle that scheduled nothing and still moved a
        /// product, a removal's. `treeFolders` is the event's: the folder of the tree
        /// product each path is an entry of.
        case result(changed: [String], appeared: [String], disappeared: [String], counts: SettleCounts?,
                    treeFolders: [String: String])
        /// The new failures the settle's `errors` event carried, as the report reads them.
        case errors(records: [ErrorRecord])
    }

    /// Unique within one planner, in the order cards were made. A running card's result
    /// keeps its id, which is what keeps it in its place.
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
        case .running: return .running
        case .result:  return .result
        case .errors:  return .errors
        }
    }

    /// The products the card names, in the order it names them: for a result, what
    /// changed, then what appeared, then what disappeared; for errors, the products
    /// without a value in path order. A tree product is named once, by its folder. A
    /// running card names nodes, not products.
    public var products: [StoppedProduct] {
        switch content {
        case .running:
            return []
        case .result:
            let moved = movedProducts
            return moved.changed + moved.appeared + moved.disappeared
        case .errors(let records):
            var seen: Set<String> = []
            return records
                .flatMap(\.products)
                .map { $0.treeFolder.map { StoppedProduct(path: $0, treeFolder: $0) } ?? $0 }
                .sorted { $0.path < $1.path }
                .filter { seen.insert($0.path).inserted }
        }
    }

    /// A result's three lists as products, each tree once by its folder and in the first
    /// list one of its entries is in: a tree with one entry changed and another appeared is
    /// a tree that changed, which is what a person rebuilding it would call it. Empty for
    /// any other card.
    public var movedProducts: MovedProducts {
        guard case .result(let changed, let appeared, let disappeared, _, let treeFolders) = content else {
            return MovedProducts(changed: [], appeared: [], disappeared: [])
        }
        var seen: Set<String> = []
        func named(_ paths: [String]) -> [StoppedProduct] {
            paths
                .map { path in treeFolders[path].map { StoppedProduct(path: $0, treeFolder: $0) } ?? StoppedProduct(path: path) }
                .filter { seen.insert($0.path).inserted }
        }
        let changedProducts  = named(changed)
        let appearedProducts = named(appeared)
        return MovedProducts(changed: changedProducts, appeared: appearedProducts, disappeared: named(disappeared))
    }
}

/// A result card's products by what the settle did to them.
public struct MovedProducts: Equatable, Sendable {
    public let changed:     [StoppedProduct]
    public let appeared:    [StoppedProduct]
    public let disappeared: [StoppedProduct]
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
    /// The running card on screen, redrawn: a `progress` moved it.
    case progressed(Card)
    /// The running card on screen became its settle's result or errors card, in its place
    /// in the stack and under its id.
    case resolved(Card)
}
