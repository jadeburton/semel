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
    ///
    /// The ports travel with every item, whether or not a renderer writes them out: they
    /// are how a caller counts the failures behind a report, and `lines` is where the
    /// question of writing them is answered.
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

    /// What to call a node in a report: `Type #id 'path'`, the form a `check` finding names
    /// it by, so that one node reads the same wherever the user meets it. The id stays even
    /// beside a path — a line in a report is what someone pastes into a bug, and the row is
    /// what the next person opens. A builder has no path of its own and is named by its
    /// project file.
    public static func label(forNodeID nodeID: ObjectID, database: DatabaseLayer) -> String {
        // A label for a report is best effort — the report must never fail — but a machine
        // failure on the way to it still reaches the fatal handler.
        guard let nodeRecord = FatalErrors.attempt({ try database.node.find(nodeID: nodeID) }) ?? nil else {
            return GraphCheck.subject(missingNodeID: nodeID)
        }

        if let path = nodeRecord.properties["path"] {
            return GraphCheck.subject(nodeRecord, path: path)
        }

        let projectFile = FatalErrors.attempt({
            try database.wire.select(goingToNodeID: nodeID, toSymbolID: "projectFile".asSymbolID())
        })?.first?.name.resolveSymbol()
        return GraphCheck.subject(nodeRecord, path: projectFile)
    }

    /// The lines for one node's errors: a heading, then one entry per distinct message.
    ///
    /// Grouped by message rather than by port, because a node that fails usually fails on all
    /// of its ports at once with the same reason — gathering them onto one item says that
    /// once, where an item per port says the same thing three times and buries how many
    /// distinct problems there actually are. Whether the ports are then written out is the
    /// renderers' question, answered in `lines`.
    ///
    /// `messages` is the caller's selection. Passing fewer than the node has is how the engine
    /// reports only what is new.
    public static func entry(forNodeID nodeID: ObjectID,
                             ports: [OutputPort],
                             messages: Set<String>,
                             database: DatabaseLayer,
                             downstreamCarrierCount: Int = 0,
                             sourceMessages: [ObjectID: String] = [:]) -> Entry {
        let items = messages.sorted().map { message -> Item in
            // Matched by what each port reports rather than by the text it stores, so that a
            // port whose state is its whole message is named alongside the rest.
            let portNames = ports
                .filter { self.message(of: $0, sourceMessages: sourceMessages) == message }
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
    ///
    /// One item carrying one port is written without the port's name. The names are there
    /// to tell one item from another and to say which of a node's ports a message came
    /// from, and a lone port does neither — `output:` on a file and `pinned:` on a folder
    /// repeat the heading in the engine's own vocabulary and carry nothing.
    ///
    /// The names stay wherever the entry accounts for more than one thing, which is also
    /// what keeps the report agreeing with the counts printed beside it: those are sums of
    /// ports, so a heading reading `3 errors` sits above lines naming three ports. One item
    /// and its port count are what both renderers can see, which is what keeps this one
    /// rule on both sides of the wire instead of a special case per message.
    public static func lines(for entry: Entry) -> [String] {
        var result = ["❌ \(entry.label)"]
        let namesPorts = !(entry.items.count == 1 && entry.items[0].ports.count == 1)

        for item in entry.items {
            let prefix = namesPorts ? "\(item.ports.joined(separator: ", ")): " : ""

            let body = item.message
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard !body.isEmpty else {
                result.append("   · \(prefix)(no details)")
                continue
            }

            if body.count == 1 {
                result.append("   · \(prefix)\(body[0])")
            } else if namesPorts {
                result.append("   · \(item.ports.joined(separator: ", ")):")
                result.append(contentsOf: body.map { "     \($0)" })
            } else {
                result.append("   · \(body[0])")
                result.append(contentsOf: body.dropFirst().map { "     \($0)" })
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
    ///
    /// A removed source reads as its state too. The sentence the report prefers names the
    /// path, which takes the graph around the port rather than the port alone, so this is
    /// what a caller without that reading falls back to.
    public static func reportableMessage(of port: OutputPort) -> String? {
        switch port.valueKind {
        case .value, .pending, .initializing, .inputNotProduced:
            return nil

        case .inputInError:
            return "\(NoValueReason.inputInError)"

        case .deleted:
            return "\(NoValueReason.deleted)"

        case .error:
            let message = (try? port.dataObjectHash?.resolveAsString()) ?? ""
            return message.isEmpty ? Self.emptyMessage : message
        }
    }

    /// What stands in for an error whose message is empty.
    public static let emptyMessage = "an error with no message"

    // MARK: - What a source's state reads as

    /// How a source is named in a report line: the path relative to the input file system,
    /// because that is what `push` takes — the reader can act on the line by typing it. The
    /// label above it carries the full path.
    ///
    /// A folder ends in a separator, the way a tree is written everywhere else in Semel, so
    /// that a line about one is not read as a line about a file of the same name.
    static func sourcePath(_ path: String, isTree: Bool) -> String {
        let full = Path(path)
        let relative = full.relative(to: Path(FileSystemName.input)) ?? full
        return isTree ? "\(relative.string)/" : relative.string
    }

    /// What a report says about a source the formula names and nobody has pushed.
    public static func unpushedFileMessage(path: String, isTree: Bool = false) -> String {
        "\(sourcePath(path, isTree: isTree)) has not been pushed"
    }

    /// What a report says about a source that was pushed and then removed.
    public static func deletedSourceMessage(path: String, isTree: Bool = false) -> String {
        "\(sourcePath(path, isTree: isTree)) was deleted"
    }

    /// The kinds whose nodes declare no input ports.
    ///
    /// Such a node is a source: the graph never schedules it, so a port of one that has
    /// never produced a value never will. Asked of the registry rather than kept as a list,
    /// which would go stale the day a type is added.
    static var sourceNodeKinds: [UInt] {
        TypeRegistry.registeredTypes.compactMap { type in
            guard let nodeType = type as? any Node.Type, !nodeType.descriptor.hasInputs else {
                return nil
            }
            return nodeType.kind
        }
    }

    /// Every port a report has to look at, for the two callers that make one.
    public static func portsToReport(database: DatabaseLayer) throws -> [OutputPort] {
        try database.outputPort.selectAllForErrorReport(sourceNodeKinds: sourceNodeKinds)
    }

    /// What the sources in this set of ports have to say for themselves, by node.
    ///
    /// A source's state is not a message: it is the graph around it — a node with no
    /// inputs, a path the reader can type, and a consumer that needs what it does not have
    /// — that turns the state into a line. This is that reading, for both of the states a
    /// source can be in that a report has to explain, in one walk of the ports.
    ///
    /// **Nobody has pushed it.** A source node's port holding the initializing state will
    /// hold it for good, so the only question is whether anyone is waiting. A consumer that
    /// reads an absent value as nothing to add says so on the port it reads, and a source
    /// whose every reader says that is one the formula allows never to exist. One wire
    /// query per candidate node, and a graph whose sources are all pushed has no candidates.
    ///
    /// The readers asked about are the node's, not the port's. A source need not carry its
    /// absence on the port its readers wire from: a folder says it has never been pushed
    /// into on `pinned` while a formula reading it as a tree wires from `manifest`, where
    /// an empty listing is what a folder with nothing in it has to offer. What is being
    /// asked is whether anything in the graph needs this source, and that is a question
    /// about the node.
    ///
    /// **It was pushed and then removed.** Named whether or not anything still reads it,
    /// which is where the two part company: a source that never existed is a fact about a
    /// formula nobody has finished, while one that was there and went is a change to the
    /// graph's inputs, and it is the same line a reader needed when a removal broke a build.
    static func sourceMessages(amongPorts ports: [OutputPort],
                               database: DatabaseLayer) -> [ObjectID: String] {

        var descriptors: [UInt: NodeDescriptor] = [:]
        var result: [ObjectID: String] = [:]

        /// The descriptor for a node id, kept by kind: one graph holds thousands of nodes
        /// of a handful of types.
        func descriptor(ofNodeID nodeID: ObjectID) -> NodeDescriptor? {
            guard let record = FatalErrors.attempt({ try database.node.find(nodeID: nodeID) }) ?? nil else {
                return nil
            }
            if let known = descriptors[record.kind] {
                return known
            }
            guard let type = try? TypeRegistry.type(kind: record.kind) as? any Node.Type else {
                return nil
            }
            descriptors[record.kind] = type.descriptor
            return type.descriptor
        }

        /// Whether anything wired below this node demands what it does not have.
        func anythingNeeds(_ nodeID: ObjectID) -> Bool {
            // A report is best effort: wires the database cannot hand over leave the source
            // unnamed, which costs a line rather than printing a wrong one.
            let consumers = FatalErrors.attempt({
                try database.wire.select(comingFromNodeID: nodeID)
            }) ?? []

            return consumers.contains { wire in
                guard let descriptor = descriptor(ofNodeID: wire.toNodeID) else {
                    return true
                }
                return !descriptor.toleratesAbsentValue(onInputPort: wire.toSymbolID.resolveSymbol())
            }
        }

        for port in ports where port.valueKind == .initializing || port.valueKind == .deleted {
            guard result[port.nodeID] == nil,
                  let record = FatalErrors.attempt({ try database.node.find(nodeID: port.nodeID) }) ?? nil,
                  let path = record.properties["path"] else {
                continue
            }
            let isTree = record.kind == Folder.kind

            if port.valueKind == .deleted {
                result[port.nodeID] = deletedSourceMessage(path: path, isTree: isTree)
            } else if anythingNeeds(port.nodeID) {
                result[port.nodeID] = unpushedFileMessage(path: path, isTree: isTree)
            }
        }

        return result
    }

    /// The message a port carries, with what the sources say already worked out.
    static func message(of port: OutputPort, sourceMessages: [ObjectID: String]) -> String? {
        // A port that has never been processed says nothing by itself, so it has a line
        // only when the reading above gave it one.
        if port.valueKind == .initializing {
            return sourceMessages[port.nodeID]
        }
        // A removed source always has a line; naming its path is better than its state, and
        // the state is what is left when the node has no path.
        if port.valueKind == .deleted {
            return sourceMessages[port.nodeID] ?? reportableMessage(of: port)
        }
        return reportableMessage(of: port)
    }

    /// What each node has to say, for a caller keeping track of what it has already said.
    ///
    /// `sourceMessages` is a parameter so that a caller making several passes over one set
    /// of ports works the sources out once; leaving it out asks for them here.
    public static func messagesByNode(forPorts ports: [OutputPort],
                                      database: DatabaseLayer,
                                      sourceMessages: [ObjectID: String]? = nil) -> [ObjectID: Set<String>] {
        let sourced = sourceMessages ?? Self.sourceMessages(amongPorts: ports, database: database)

        var result: [ObjectID: Set<String>] = [:]
        for port in ports {
            guard let message = message(of: port, sourceMessages: sourced) else {
                continue
            }
            result[port.nodeID, default: []].insert(message)
        }
        return result
    }

    // MARK: - Folding a cascade onto its cause

    /// Whether a port says only that something upstream of its node failed.
    ///
    /// The port holds that as a state of its own, so the question is answered by asking what
    /// the port is rather than by reading what it says.
    public static func isCarriedFromAnInput(_ port: OutputPort) -> Bool {
        port.valueKind == .inputInError
    }

    /// Whether a port says only that a value its node needed was never produced.
    ///
    /// A second way of carrying someone else's state, and folded the same way — the node
    /// below a file nobody pushed has nothing of its own to say either. It differs in what
    /// happens when the walk finds no cause: a failure that was collected leaves its carrier
    /// standing in for it, where an absence with no cause above it is the state of a node
    /// whose turn has not come, which a report passes over.
    public static func isCarriedFromAnAbsentInput(_ port: OutputPort) -> Bool {
        port.valueKind == .inputNotProduced
    }

    /// The nodes worth reporting, each with the number of nodes downstream that fail only
    /// because it did.
    ///
    /// A node whose every listed port carries someone else's state — an input that failed,
    /// or an input that never had a value — is folded into the causes the wires reach
    /// upstream of it; a node with anything of its own to say is a cause and is reported.
    /// The two kinds of carrier are folded alike and part company only where the walk ends.
    /// A carrier of a failure with nothing failing upstream is as far as the walk can go,
    /// which means the node that failed has been collected, so the carrier stands in for its
    /// own cause; a carrier of an absence with nothing above it is a node whose turn has not
    /// come, which is the state of every node in a fresh graph, so it is dropped.
    ///
    /// The fold reaches exactly as far as the wires do: a chain of carriers folds onto its
    /// topmost, while sibling consumers of one absent node share no wire to walk along and
    /// are a cause each. The collector is what keeps the second shape away from a report —
    /// `collectIfUnreferenced` takes a node only once `hasNoOutputWires` holds of it, so
    /// every consumer goes before the node it reads, and a graph holding carriers whose
    /// cause has been collected is not one an idle pass sees.
    public static func causes(amongErrorPorts byNode: [ObjectID: [OutputPort]],
                              database: DatabaseLayer) -> [ObjectID: Int] {
        causes(amongErrorPorts: byNode,
               database: database,
               sourceMessages: sourceMessages(amongPorts: byNode.values.flatMap { $0 }, database: database))
    }

    static func causes(amongErrorPorts byNode: [ObjectID: [OutputPort]],
                       database: DatabaseLayer,
                       sourceMessages: [ObjectID: String]) -> [ObjectID: Int] {

        var reporting: [ObjectID: [OutputPort]] = [:]
        for (nodeID, ports) in byNode {
            let listed = ports.filter {
                message(of: $0, sourceMessages: sourceMessages) != nil || isCarriedFromAnAbsentInput($0)
            }
            if !listed.isEmpty {
                reporting[nodeID] = listed
            }
        }

        let carriers = Set(reporting.filter {
            $0.value.allSatisfy { isCarriedFromAnInput($0) || isCarriedFromAnAbsentInput($0) }
        }.keys)

        /// Whether a carrier with no cause above it has anything of its own to stand in for.
        /// A failure whose cause has been collected does; a value that was never produced
        /// does not, and passing over it is what keeps a fresh graph out of the report.
        func standsInForItsOwnCause(_ nodeID: ObjectID) -> Bool {
            reporting[nodeID]?.contains(where: isCarriedFromAnInput) ?? false
        }

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
            // along. A carrier of an absence has no such cause to stand in for and drops out
            // of the report, as every node between its creation and its first run does.
            var result = found
            if found.isEmpty && standsInForItsOwnCause(nodeID) {
                result = [nodeID]
            }

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
    /// one label apart from the id — two of a type with no path do. A sort by label alone
    /// leaves those two in the order the walk found them, `sort` being no more stable than the
    /// key it is given. The id is left out of the label the sort reads and kept as the tie
    /// break: compared as text it puts `#10` before `#9`, and it would order a folder's files
    /// by when their nodes were made rather than by their paths.
    ///
    /// `sourceMessages` is a parameter for the same reason it is one on `messagesByNode`: the
    /// engine makes three passes over one idle pass's ports and works the sources out once.
    public static func entries(forErrorPorts errorPorts: [OutputPort],
                               database: DatabaseLayer,
                               sourceMessages: [ObjectID: String]? = nil,
                               select: (ObjectID, Set<String>) -> Set<String>)
                               -> [(nodeID: ObjectID, entry: Entry)] {

        let byNode   = Dictionary(grouping: errorPorts, by: \.nodeID)
        let sourced = sourceMessages ?? Self.sourceMessages(amongPorts: errorPorts, database: database)
        let counts   = causes(amongErrorPorts: byNode, database: database, sourceMessages: sourced)

        var reported: [(nodeID: ObjectID, entry: Entry)] = []

        for (nodeID, carriedCount) in counts {
            let ports    = byNode[nodeID] ?? []
            let selected = select(nodeID, Set(ports.compactMap { message(of: $0, sourceMessages: sourced) }))
            guard !selected.isEmpty else {
                continue
            }

            reported.append((nodeID, entry(forNodeID: nodeID,
                                           ports: ports,
                                           messages: selected,
                                           database: database,
                                           downstreamCarrierCount: carriedCount,
                                           sourceMessages: sourced)))
        }

        func sortLabel(_ report: (nodeID: ObjectID, entry: Entry)) -> String {
            report.entry.label.replacingOccurrences(of: " #\(report.nodeID)", with: "")
        }
        return reported.sorted { (sortLabel($0), $0.nodeID) < (sortLabel($1), $1.nodeID) }
    }
}
