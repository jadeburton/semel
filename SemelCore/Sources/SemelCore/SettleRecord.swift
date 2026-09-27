// SettleRecord.swift
// SemelCore
//
// What the last settle did, node by node, and what woke each node (B-91).
//
// The settle summary counts; this names. The tally that the summary is taken from already
// knows which nodes ran and which the cache answered, and the write path knows, for an
// instant, which wire's value scheduled which consumer. The recorder keeps both until the
// settle is reported and then hands them over as one finished record, which `explain`
// reads. One record, the last settle's, in memory: see the design document
// (docs/superpowers/specs/2026-09-27-semel-explain-design.md) for why not a history and
// not the database.

import Foundation
import SemelDatabaseModels

/// The last settle that did work, finished: which nodes it scheduled, what each produced,
/// and the wires whose writes woke them.
public struct SettleRecord: Equatable, Sendable {

    /// What a node's latest result in the settle was.
    public enum Outcome: Equatable, Sendable {
        case computed
        case fromCache
    }

    /// Why a wire's write woke its consumer. Declared in the order a reader wants them:
    /// the first three are reasons the consumer had something new to read, the last is a
    /// reason it was woken and nothing more.
    public enum Change: Int, Comparable, Sendable {
        /// The source wrote a value other than the one the port held when the settle
        /// began — or one nobody knew, which is a value that moved for all anyone can say.
        case changed
        /// The wire was connected in this settle.
        case connected
        /// The wire was disconnected in this settle; its consumer lost an input.
        case disconnected
        /// The source wrote the value the port held when the settle began. The consumer
        /// was woken — the cascade had set the port pending in between — and has nothing
        /// new to read, which is what lets the cache answer it.
        case unchanged

        public static func < (left: Change, right: Change) -> Bool {
            left.rawValue < right.rawValue
        }
    }

    /// One wire's write that scheduled its consumer.
    public struct Wake: Hashable, Sendable {
        public let fromNodeID:       ObjectID
        public let fromPortSymbolID: ObjectID
        public let toPortSymbolID:   ObjectID
        public let wireNameSymbolID: ObjectID
        public let change:           Change

        public init(fromNodeID: ObjectID, fromPortSymbolID: ObjectID, toPortSymbolID: ObjectID,
                    wireNameSymbolID: ObjectID, change: Change) {
            self.fromNodeID       = fromNodeID
            self.fromPortSymbolID = fromPortSymbolID
            self.toPortSymbolID   = toPortSymbolID
            self.wireNameSymbolID = wireNameSymbolID
            self.change           = change
        }

        /// The wire, without what it did: two wakes on one wire are one cause.
        fileprivate var wireKey: WireKey {
            WireKey(fromNodeID: fromNodeID, fromPortSymbolID: fromPortSymbolID,
                    toPortSymbolID: toPortSymbolID, wireNameSymbolID: wireNameSymbolID)
        }
    }

    fileprivate struct WireKey: Hashable {
        let fromNodeID:       ObjectID
        let fromPortSymbolID: ObjectID
        let toPortSymbolID:   ObjectID
        let wireNameSymbolID: ObjectID
    }

    /// Every node the settle fetched as scheduled, once each.
    public internal(set) var scheduled: Set<ObjectID> = []

    /// For each node that produced a result, what its latest one was.
    public internal(set) var outcomes: [ObjectID: Outcome] = [:]

    /// Nodes created during the settle — and during the pushes that led up to it.
    public internal(set) var created: Set<ObjectID> = []

    /// Per consumer, the wires whose writes woke it: one wake per wire, the strongest
    /// change it brought, ordered by change and then by the wire's symbols so that two
    /// reads of one record list them alike.
    public internal(set) var wakes: [ObjectID: [Wake]] = [:]

    /// Nodes that produced no result of their own and whose value moved: the sources a
    /// push changed, and a folder whose manifest moved with them.
    public internal(set) var changedSources: Set<ObjectID> = []

    public init() {}

    /// Folds wakes on one wire into one — the strongest change it brought — and orders
    /// them. A source that ran twice in a settle writes its consumers twice, and a reader
    /// asking why a node ran wants the wire once.
    static func deduplicated(_ wakes: [Wake]) -> [Wake] {
        var strongest: [WireKey: Wake] = [:]
        for wake in wakes {
            if let existing = strongest[wake.wireKey], existing.change <= wake.change {
                continue
            }
            strongest[wake.wireKey] = wake
        }
        return strongest.values.sorted {
            ($0.change, $0.toPortSymbolID, $0.wireNameSymbolID, $0.fromNodeID, $0.fromPortSymbolID)
                < ($1.change, $1.toPortSymbolID, $1.wireNameSymbolID, $1.fromNodeID, $1.fromPortSymbolID)
        }
    }
}

/// What a port carried, without the row around it: what a wake compares.
struct PortValue: Equatable {
    let valueKind:      OutputPort.ValueKind
    let dataObjectHash: DataObjectHash?

    init(_ port: OutputPort) {
        self.valueKind      = port.valueKind
        self.dataObjectHash = port.dataObjectHash
    }
}

/// Collects the record while a settle runs and keeps the last one finished.
///
/// A class with a lock of its own, where the tally beside it is a struct the loop owns:
/// ports are written from the loop's task and from whichever connection thread is pushing,
/// and both reach here. `explain` reads the finished record from a request thread.
final class SettleRecorder {

    private let lock = NSLock()

    /// Wakes since the last finished record, by consumer.
    private var pendingWakes: [ObjectID: [SettleRecord.Wake]] = [:]

    /// Nodes created since the last finished record.
    private var pendingCreated: Set<ObjectID> = []

    /// Per port written since the last finished record — keyed on node and port symbol —
    /// the value it held before the first of those writes, nil for a port that had no row.
    /// What makes a wake's `change` say whether the value moved rather than whether it
    /// differs from the `pending` the cascade wrote a moment earlier.
    private var valuesAtSettleStart: [PortKey: PortValue?] = [:]

    private struct PortKey: Hashable {
        let nodeID:       ObjectID
        let portSymbolID: ObjectID
    }

    private var lastRecord: SettleRecord?

    /// The last settle that did work, finished; nil until one has since this process began.
    var last: SettleRecord? {
        lock.withLock { lastRecord }
    }

    /// The value a port held when the settle began, for a write about to replace
    /// `existing`: the first write to a port in a settle keeps what it replaces, and every
    /// later one is told that. Nil for a port that had no row then.
    func valueAtSettleStart(nodeID: ObjectID, portSymbolID: ObjectID, replacing existing: OutputPort?) -> PortValue? {
        let key = PortKey(nodeID: nodeID, portSymbolID: portSymbolID)
        return lock.withLock {
            if let kept = valuesAtSettleStart[key] {
                return kept
            }
            let value = existing.map(PortValue.init)
            valuesAtSettleStart[key] = value
            return value
        }
    }

    /// Whether a write of `written` is a change against what the port held when the settle
    /// began. A `pending` kept there is a value nobody knew — the port was mid-cascade when
    /// this settle's first write reached it — and counts as a change.
    static func change(from settleStart: PortValue?, to written: OutputPort) -> SettleRecord.Change {
        guard let settleStart, settleStart.valueKind != .pending, settleStart == PortValue(written) else {
            return .changed
        }
        return .unchanged
    }

    func noteWake(consumerNodeID: ObjectID, wire: Wire, change: SettleRecord.Change) {
        let wake = SettleRecord.Wake(fromNodeID:       wire.fromNodeID,
                                     fromPortSymbolID: wire.fromSymbolID,
                                     toPortSymbolID:   wire.toSymbolID,
                                     wireNameSymbolID: wire.name,
                                     change:           change)
        lock.withLock { pendingWakes[consumerNodeID, default: []].append(wake) }
    }

    func noteCreated(nodeID: ObjectID) {
        lock.withLock { _ = pendingCreated.insert(nodeID) }
    }

    /// Makes what was collected the last record, from the tally's three sets, and starts
    /// collecting for the next settle.
    ///
    /// A wake whose consumer this settle did not schedule is not this settle's: a push
    /// that lands between the pass ending and the report wakes nodes the *next* pass runs,
    /// so its wakes stay for the record that pass finishes.
    func finishSettle(scheduled: Set<ObjectID>, computed: Set<ObjectID>, fromCache: Set<ObjectID>) {
        lock.withLock {
            var record = SettleRecord()
            record.scheduled = scheduled
            for nodeID in computed.sorted() {
                record.outcomes[nodeID] = .computed
            }
            for nodeID in fromCache.sorted() {
                record.outcomes[nodeID] = .fromCache
            }
            record.created = pendingCreated

            var carried: [ObjectID: [SettleRecord.Wake]] = [:]
            for consumerNodeID in pendingWakes.keys.sorted() {
                let wakes = pendingWakes[consumerNodeID] ?? []
                guard scheduled.contains(consumerNodeID) else {
                    carried[consumerNodeID] = wakes
                    continue
                }
                let folded = SettleRecord.deduplicated(wakes)
                record.wakes[consumerNodeID] = folded
                for wake in folded where wake.change == .changed && record.outcomes[wake.fromNodeID] == nil {
                    record.changedSources.insert(wake.fromNodeID)
                }
            }

            lastRecord          = record
            pendingWakes        = carried
            pendingCreated      = []
            valuesAtSettleStart = [:]
        }
    }
}
