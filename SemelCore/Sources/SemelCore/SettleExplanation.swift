// SettleExplanation.swift
// SemelCore
//
// Why the last settle did what it did to one node: the walk `explain` answers with (B-91).
//
// From the node asked about, upstream through the wires whose writes woke it, into every
// node the settle touched, down to the sources a push changed. Each wire says whether it
// brought a changed value, was connected or disconnected, or brought the value it had —
// the last is how a product woken by a linker that relinked to the same bytes is told
// apart from one whose input really moved.

import SemelDatabaseModels

/// The last settle, read from one node upstream: each node on the way, what it did, and
/// the wires that reached it. Entries index one another, so a node two chains share is
/// described once.
public struct SettleExplanation: Equatable, Sendable {

    /// What a node did in the settle.
    public enum State: Equatable, Sendable {
        /// It ran.
        case computed
        /// It was woken and the cache answered it.
        case fromCache
        /// It was woken and produced nothing: an input was not ready.
        case notRun
        /// It did not run, and its value moved: a pushed file, a folder's manifest.
        case changed
        /// The settle did not reach it.
        case untouched
    }

    /// One wire that woke an entry's node.
    public struct Cause: Equatable, Sendable {
        /// The consumer's input port, and the wire's name on it.
        public let port:         String
        public let wire:         String
        public let change:       SettleRecord.Change
        public let sourceNodeID: ObjectID
        public let sourceLabel:  String
        /// Where the source is among the entries, when the walk reached it.
        public internal(set) var sourceIndex: Int?
    }

    public struct Entry: Equatable, Sendable {
        public let nodeID: ObjectID
        /// What a report calls the node: `ClangCompiler #40 'input:/src/main.c'`.
        public let label: String
        public let state: State
        /// Whether the node did not exist before the settle.
        public let isNew: Bool
        /// The wires that woke it, changed ones first; at most `causeLimit`.
        public internal(set) var causes: [Cause]
        /// How many more wires woke it than are listed.
        public let unlistedCauses: Int
    }

    /// The node asked about first, then the rest in the order the walk reached them.
    public let entries: [Entry]

    /// Nodes the walk reached and a bound left out.
    public let omittedNodes: Int

    public let nodeLimit:  Int
    public let depthLimit: Int

    // MARK: - Bounds

    /// How many nodes one answer describes. A cold build moves every wire in the graph,
    /// and an answer listing all of it is what `debug` is for.
    public static let nodeLimit = 40

    /// How many wires upstream of the node asked about the walk goes.
    public static let depthLimit = 16

    /// How many of one node's wires are named. A linker woken by every object of a large
    /// target is one line with a count, not a page.
    public static let causeLimit = 10

    // MARK: - The walk

    /// What `nodeID` did in the settle `record` describes.
    public static func state(of nodeID: ObjectID, in record: SettleRecord) -> State {
        switch record.outcomes[nodeID] {
        case .computed?:  return .computed
        case .fromCache?: return .fromCache
        case nil:         break
        }
        if record.scheduled.contains(nodeID) {
            return .notRun
        }
        return record.changedSources.contains(nodeID) ? .changed : .untouched
    }

    /// Walks breadth first from `nodeID`, so that when a bound stops it, what is left out
    /// is what lies furthest from the node asked about.
    public init(explaining nodeID: ObjectID, record: SettleRecord, database: DatabaseLayer,
                nodeLimit: Int, depthLimit: Int, causeLimit: Int) {
        var labels: [ObjectID: String] = [:]
        func label(_ labelledNodeID: ObjectID) -> String {
            if let known = labels[labelledNodeID] {
                return known
            }
            let made = ErrorReport.label(forNodeID: labelledNodeID, database: database)
            labels[labelledNodeID] = made
            return made
        }

        func entry(for entryNodeID: ObjectID) -> Entry {
            let wakes  = record.wakes[entryNodeID] ?? []
            let listed = wakes.prefix(causeLimit).map { wake in
                Cause(port:         wake.toPortSymbolID.resolveSymbol(),
                      wire:         wake.wireNameSymbolID.resolveSymbol(),
                      change:       wake.change,
                      sourceNodeID: wake.fromNodeID,
                      sourceLabel:  label(wake.fromNodeID),
                      sourceIndex:  nil)
            }
            return Entry(nodeID:         entryNodeID,
                         label:          label(entryNodeID),
                         state:          Self.state(of: entryNodeID, in: record),
                         isNew:          record.created.contains(entryNodeID),
                         causes:         listed,
                         unlistedCauses: wakes.count - listed.count)
        }

        // Which wires the walk goes up. Never into a node the settle did not touch: a wire
        // connected to one — a header a new include finder was wired to — is a reason its
        // consumer ran, named on the consumer's line, and the node behind it has nothing to
        // add. Up a wire that brought a changed value, always. Up one that brought the value
        // it had, only from a node that ran: a linker that ran on a changed setting and
        // wrote the bytes it wrote before woke its product with an unchanged value, and the
        // product was rebuilt all the same — the linker's run is the answer. A node the
        // cache answered has nothing more to explain on such a wire: nothing new reached it
        // there, and whatever woke its source is told where it made a difference.
        func isFollowed(_ change: SettleRecord.Change, from sourceNodeID: ObjectID,
                        into consumerNodeID: ObjectID) -> Bool {
            guard Self.state(of: sourceNodeID, in: record) != .untouched else {
                return false
            }
            return change != .unchanged || Self.state(of: consumerNodeID, in: record) != .fromCache
        }

        var entries = [entry(for: nodeID)]
        var depths  = [0]
        var indexByNodeID: [ObjectID: Int] = [nodeID: 0]

        var head = 0
        while head < entries.count {
            let depth      = depths[head]
            let consumerID = entries[head].nodeID
            for cause in entries[head].causes where isFollowed(cause.change, from: cause.sourceNodeID, into: consumerID) {
                guard indexByNodeID[cause.sourceNodeID] == nil,
                      depth < depthLimit, entries.count < nodeLimit else {
                    continue
                }
                indexByNodeID[cause.sourceNodeID] = entries.count
                entries.append(entry(for: cause.sourceNodeID))
                depths.append(depth + 1)
            }
            head += 1
        }

        // An index only on a wire the walk goes up, so a source reached by another path is
        // not drawn under a consumer that has nothing to learn from it.
        for entryIndex in entries.indices {
            let consumerID = entries[entryIndex].nodeID
            for causeIndex in entries[entryIndex].causes.indices {
                let cause = entries[entryIndex].causes[causeIndex]
                guard isFollowed(cause.change, from: cause.sourceNodeID, into: consumerID) else {
                    continue
                }
                entries[entryIndex].causes[causeIndex].sourceIndex = indexByNodeID[cause.sourceNodeID]
            }
        }

        // Everything the walk would reach with no bound: the record is in memory, so the
        // count costs no reads, and "and N more" is exact.
        var reachable: Set<ObjectID> = [nodeID]
        var pending = [nodeID]
        while let consumerNodeID = pending.popLast() {
            for wake in record.wakes[consumerNodeID] ?? []
            where isFollowed(wake.change, from: wake.fromNodeID, into: consumerNodeID) {
                if reachable.insert(wake.fromNodeID).inserted {
                    pending.append(wake.fromNodeID)
                }
            }
        }

        self.entries      = entries
        // Every entry was reached by the same rule, so the entries are a subset of what is
        // reachable and the difference is what the bounds left out.
        self.omittedNodes = reachable.count - indexByNodeID.count
        self.nodeLimit    = nodeLimit
        self.depthLimit   = depthLimit
    }
}

extension BuildEngine {

    /// Why the last settle did what it did to `nodeID`, within the standard bounds; nil
    /// when no settle has done work since this engine started.
    public func explain(nodeID: ObjectID) -> SettleExplanation? {
        guard let record = lastSettleRecord else {
            return nil
        }
        return SettleExplanation(explaining: nodeID, record: record, database: database,
                                 nodeLimit:  SettleExplanation.nodeLimit,
                                 depthLimit: SettleExplanation.depthLimit,
                                 causeLimit: SettleExplanation.causeLimit)
    }
}
