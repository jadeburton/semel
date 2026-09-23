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
            // Matched by what each port reports rather than by the text it stores, so that a
            // port whose state is its whole message is named alongside the rest.
            let portNames = ports
                .filter { reportableMessage(of: $0) == message }
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
    /// Decided by the port's state, not by its text. A port holding a value or waiting for
    /// one has no failure to report; neither has a port where no value has ever been
    /// produced, nor one whose node could not produce because of such a port — nothing has
    /// failed anywhere above either of them, and reporting the first would announce an error
    /// for every node in a fresh graph. A node that did not run because an input failed has
    /// no message of its own, so it reports the sentence its state reads as. An error with no
    /// text at all is still an error, and the one kind a reader cannot diagnose, so it is
    /// reported as exactly that rather than dropped.
    public static func reportableMessage(of port: OutputPort) -> String? {
        switch port.valueKind {
        case .value, .pending, .initializing, .inputNotProduced:
            return nil

        case .inputInError:
            return "\(NoValueReason.inputInError)"

        case .error:
            let message = (try? port.dataObjectHash?.resolveAsString()) ?? ""
            return message.isEmpty ? Self.emptyMessage : message
        }
    }

    /// What stands in for an error whose message is empty.
    public static let emptyMessage = "an error with no message"

    // MARK: - Folding a cascade onto its cause

    /// Whether a port says only that something upstream of its node failed.
    ///
    /// The port holds that as a state of its own, so the question is answered by asking what
    /// the port is rather than by reading what it says.
    public static func isCarriedFromAnInput(_ port: OutputPort) -> Bool {
        port.valueKind == .inputInError
    }

    /// The nodes worth reporting, each with the number of nodes downstream that fail only
    /// because it did.
    ///
    /// A node whose every reportable port is carried from an input is carrying someone
    /// else's failure, and is folded into the causes the wires reach upstream of it; a node with
    /// anything else to say is a cause and is reported. A carrier with nothing failing
    /// upstream is as far as the walk can go, which means the node that failed has been
    /// collected, so the carrier stands in for its own cause. A chain below a value that
    /// was never produced never reaches here: nothing in it is a carrier, because a node
    /// stopped by an input that has no value publishes that state rather than a failure. That fold reaches exactly as far as the wires do: a
    /// chain of carriers folds onto its topmost, while sibling consumers of one absent node
    /// share no wire to walk along and are a cause each. The collector is what keeps the
    /// second shape away from a report — `collectIfUnreferenced` takes a node only once
    /// `hasNoOutputWires` holds of it, so every consumer goes before the node it reads, and
    /// a graph holding carriers whose cause has been collected is not one an idle pass sees.
    public static func causes(amongErrorPorts byNode: [ObjectID: [OutputPort]],
                              database: DatabaseLayer) -> [ObjectID: Int] {

        var reporting: [ObjectID: [OutputPort]] = [:]
        for (nodeID, ports) in byNode {
            let reportable = ports.filter { reportableMessage(of: $0) != nil }
            if !reportable.isEmpty {
                reporting[nodeID] = reportable
            }
        }

        let carriers = Set(reporting.filter { $0.value.allSatisfy(isCarriedFromAnInput) }.keys)

        var counts: [ObjectID: Int] = [:]
        for nodeID in reporting.keys where !carriers.contains(nodeID) {
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
            for source in Set(upstream) where reporting[source] != nil {
                if carriers.contains(source) {
                    found.formUnion(causeIDs(of: source, walking: walking.union([nodeID])))
                } else {
                    found.insert(source)
                }
            }

            // Nothing failing upstream: the cause has been collected, and this carrier
            // stands in for it. That folds the carriers wired below it onto this one
            // and reaches no further, siblings of it having no wire between them to be folded
            // along.
            let result = found.isEmpty ? [nodeID] : found

            // Memoised per node rather than per (node, path), which is exact for a DAG and
            // is what makes one answer serve every carrier below it. Wire creation rejects a
            // cycle, so the `walking` guard above is a belt on a graph that cannot have one.
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
