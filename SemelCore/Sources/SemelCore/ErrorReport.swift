// ErrorReport.swift
// SemelCore
//
// How a node's errors are written out, in the one place that decides it.
//
// Two callers want this: the engine, which reports errors as it settles, and the CLI's
// `errors` command, which reports them on request. They differ in *which* errors they show —
// the engine only what is newly appearing, the command everything — and that is a question
// about selection, not about shape. Answering the shape twice gave a failure one form when
// it appeared by itself and another when it was asked for, both under the same ❌.

import SemelDatabaseModels
import SemelNodeKit

/// One node's errors, rendered.
public enum ErrorReport {

    /// One distinct message a node is carrying, and the ports carrying it.
    public struct Item: Equatable {
        public let ports:   [String]
        public let message: String

        public init(ports: [String], message: String) {
            self.ports   = ports
            self.message = message
        }
    }

    /// One node's errors, gathered but not yet rendered. The engine hands these to its
    /// reporter, and a server turns them into wire records; only the terminal turns them
    /// into lines.
    public struct Entry: Equatable {
        public let label: String
        public let items: [Item]
        /// How many nodes downstream of this one fail only because this one did. They are
        /// folded into a count instead of a line each: one deleted header stops every node
        /// that reads it, and the reader can act on the header alone.
        public let downstreamCarrierCount: Int

        public init(label: String, items: [Item], downstreamCarrierCount: Int = 0) {
            self.label                  = label
            self.items                  = items
            self.downstreamCarrierCount = downstreamCarrierCount
        }
    }

    /// What to call a node in a report.
    ///
    /// The internal id is a surrogate integer and means nothing to the person reading, so it
    /// is the last resort rather than the first: a path if the node has one, the project file
    /// if it is a builder, the type name otherwise.
    public static func label(forNodeID nodeID: ObjectID, database: DatabaseLayer) -> String {
        // A label for a report is best effort — the report must never fail — but a machine
        // failure on the way to it still reaches the fatal handler.
        guard let nodeRecord = FatalErrors.attempt({ try database.node.find(nodeID: nodeID) }) ?? nil,
              let node = try? nodeRecord.nodeAsAny() else {
            return "Node \(nodeID)"
        }

        let typeName = String(describing: type(of: node))

        if let path = nodeRecord.properties["path"] {
            return "\(typeName)  '\(path)'"
        }

        if let wires = FatalErrors.attempt({
               try database.wire.select(goingToNodeID: nodeID, toSymbolID: "projectFile".asSymbolID())
           }),
           let wireName = wires.first?.name {
            return "\(typeName)  '\(wireName.resolveSymbol())'"
        }

        return typeName
    }

    /// The lines for one node's errors: a heading, then one entry per distinct message.
    ///
    /// Grouped by message rather than by port, because a node that fails usually fails on all
    /// of its ports at once with the same reason — `errorLog, infoLog, output: …` says that in
    /// one line, where a line per port says the same thing three times and buries how many
    /// distinct problems there actually are.
    ///
    /// `messages` is the caller's selection. Passing fewer than the node has is how the engine
    /// reports only what is new.
    public static func entry(forNodeID nodeID: ObjectID,
                             ports: [OutputPort],
                             messages: Set<String>,
                             database: DatabaseLayer,
                             downstreamCarrierCount: Int = 0) -> Entry {
        let items = messages.sorted().map { message -> Item in
            let portNames = ports
                .filter { ((try? $0.dataObjectHash?.resolveAsString()) ?? "") == message }
                .map { $0.nameSymbolID.resolveSymbol() }
                .sorted()
            return Item(ports: portNames, message: message)
        }
        return Entry(label: label(forNodeID: nodeID, database: database),
                     items: items,
                     downstreamCarrierCount: downstreamCarrierCount)
    }

    /// The lines for one entry: a heading, then one line per item, or an indented block
    /// when a message spans lines. `SemelCLI` has a twin of this over the wire record; the
    /// two must stay identical, and `IdleErrorReportingTests` pins this one's output.
    public static func lines(for entry: Entry) -> [String] {
        var result = ["❌ \(entry.label)"]

        for item in entry.items {
            let portNames = item.ports.joined(separator: ", ")

            let body = item.message
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard !body.isEmpty else {
                result.append("   · \(portNames): (no details)")
                continue
            }

            if body.count == 1 {
                result.append("   · \(portNames): \(body[0])")
            } else {
                result.append("   · \(portNames):")
                result.append(contentsOf: body.map { "     \($0)" })
            }
        }

        if let carried = carriedLine(count: entry.downstreamCarrierCount) {
            result.append("   · \(carried)")
        }

        result.append("")
        return result
    }

    /// The one line a whole cascade reads as, or nil when nothing is downstream. `semel`'s
    /// `ErrorRecordRenderer` has a twin of this, as it does of every line here.
    public static func carriedLine(count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1:    return "and 1 node downstream carries it"
        default:   return "and \(count) nodes downstream carry it"
        }
    }

    public static func lines(forNodeID nodeID: ObjectID,
                             ports: [OutputPort],
                             messages: Set<String>,
                             database: DatabaseLayer) -> [String] {
        lines(for: entry(forNodeID: nodeID, ports: ports, messages: messages, database: database))
    }

    /// The message a port is carrying, or nil when it carries nothing worth reporting.
    ///
    /// `initializing` is the placeholder every node holds between being created and first
    /// processing, so reporting it would announce an error for every node in a fresh graph.
    /// An error with no text at all is still an error, and the one kind a reader cannot
    /// diagnose, so it is reported as exactly that rather than dropped.
    public static func reportableMessage(of port: OutputPort) -> String? {
        let message = (try? port.dataObjectHash?.resolveAsString()) ?? ""
        guard message != NodeError.initializingMessage else {
            return nil
        }
        return message.isEmpty ? Self.emptyMessage : message
    }

    /// What stands in for an error whose message is empty.
    public static let emptyMessage = "an error with no message"

    // MARK: - Folding a cascade onto its cause

    /// Whether a message says only that something upstream of the node failed.
    ///
    /// A port holds its error as `NoValueReason.error(messageDataObjectHash:)` — the hash of
    /// the interned sentence, and nothing about which `NodeError` wrote it — so the sentence
    /// is the only signal there is. The comparison is against the one constant
    /// `NodeError.inputValueInError` renders, the way `initializing` is matched, rather than
    /// against a sentence spelled out twice.
    public static func isCarriedFromAnInput(_ message: String) -> Bool {
        message == NodeError.inputValueInErrorMessage
    }

    /// The nodes worth reporting, each with the number of nodes downstream that fail only
    /// because it did.
    ///
    /// A node whose every message is carried from an input is carrying someone else's
    /// failure, and is folded into the causes the wires reach upstream of it; a node with
    /// anything else to say is a cause and is reported. A carrier with nothing failing
    /// upstream is as far as the walk can go — the node that failed has been collected — so
    /// it stands in for its own cause and is reported once, with whatever it carries folded
    /// under it.
    public static func causes(amongErrorPorts byNode: [ObjectID: [OutputPort]],
                              database: DatabaseLayer) -> [ObjectID: Int] {

        var messages: [ObjectID: Set<String>] = [:]
        for (nodeID, ports) in byNode {
            let reportable = Set(ports.compactMap(reportableMessage))
            if !reportable.isEmpty {
                messages[nodeID] = reportable
            }
        }

        let carriers = Set(messages.filter { $0.value.allSatisfy(isCarriedFromAnInput) }.keys)

        var counts: [ObjectID: Int] = [:]
        for nodeID in messages.keys where !carriers.contains(nodeID) {
            counts[nodeID] = 0
        }

        // One walk per carrier, memoised: a graph where a thousand nodes read one header
        // has a thousand carriers whose answer is the same node.
        var walked: [ObjectID: Set<ObjectID>] = [:]

        func causeIDs(of nodeID: ObjectID, walking: Set<ObjectID>) -> Set<ObjectID> {
            if let known = walked[nodeID] {
                return known
            }
            guard !walking.contains(nodeID) else {
                return []
            }

            // A report is best effort: a wire the database cannot hand over leaves the
            // carrier standing in for its own cause, which is still one line rather than none.
            let upstream = FatalErrors.attempt({ try database.wire.select(goingToNodeID: nodeID) })?
                .map(\.fromNodeID) ?? []

            var found: Set<ObjectID> = []
            for source in Set(upstream) where messages[source] != nil {
                if carriers.contains(source) {
                    found.formUnion(causeIDs(of: source, walking: walking.union([nodeID])))
                } else {
                    found.insert(source)
                }
            }

            let result = found.isEmpty ? [nodeID] : found
            walked[nodeID] = result
            return result
        }

        for carrier in carriers {
            for cause in causeIDs(of: carrier, walking: []) {
                if cause == carrier {
                    counts[carrier] = counts[carrier] ?? 0
                } else {
                    counts[cause, default: 0] += 1
                }
            }
        }

        return counts
    }

    /// Every failing node's errors, the cascade folded onto its causes, in report order.
    ///
    /// This is the whole of what a report is, so that the engine's idle-time event and the
    /// `errors` verb's reply say the same thing: they differ only in `select`, which narrows
    /// one node's messages to the ones that caller wants — the engine to what is newly
    /// appearing, the verb to everything. A node left with nothing is not reported, and the
    /// node id comes back beside each entry for a caller keeping its own accounts.
    ///
    /// Sorted by label and then by node, so a report reads the same from run to run: the
    /// error map is a dictionary, whose order is seeded per process, and two nodes can carry
    /// one label — two of a type with no path do. A sort by label alone leaves those two in
    /// the order the walk found them, `sort` being no more stable than the key it is given.
    public static func entries(forErrorPorts errorPorts: [OutputPort],
                               database: DatabaseLayer,
                               select: (ObjectID, Set<String>) -> Set<String>)
                               -> [(nodeID: ObjectID, entry: Entry)] {

        let byNode = Dictionary(grouping: errorPorts, by: \.nodeID)
        let counts = causes(amongErrorPorts: byNode, database: database)

        var reported: [(nodeID: ObjectID, entry: Entry)] = []

        for (nodeID, carriedCount) in counts {
            let ports    = byNode[nodeID] ?? []
            let selected = select(nodeID, Set(ports.compactMap(reportableMessage)))
            guard !selected.isEmpty else {
                continue
            }

            reported.append((nodeID, entry(forNodeID: nodeID,
                                           ports: ports,
                                           messages: selected,
                                           database: database,
                                           downstreamCarrierCount: carriedCount)))
        }

        return reported.sorted { ($0.entry.label, $0.nodeID) < ($1.entry.label, $1.nodeID) }
    }
}
