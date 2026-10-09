// ErrorReport.swift
// SemelCore
//
// Which failures the graph holds, in the one place that decides it.
//
// Two callers want this: the engine, which reports errors as it settles, and the server's
// `errors` verb, which reports them on request. They differ in *which* errors they show —
// the engine only what is newly appearing, the verb everything — and that is a question
// about selection, not about shape. Neither renders anything: an entry carries each
// node's `ErrorDocument`s as values, and the client draws the lines.

import SemelDatabaseModels
import SemelNodeKit

/// The graph's failures, gathered.
public enum ErrorReport {

    /// One distinct document a node is carrying, and the ports carrying it.
    ///
    /// The ports travel with every item: they are what `--verbose` names, and a node whose
    /// ports carry two different documents has two items.
    public struct Item: Hashable {
        public let ports:    [String]
        public let document: ErrorDocument

        public init(ports: [String], document: ErrorDocument) {
            self.ports    = ports
            self.document = document
        }
    }

    /// One node's errors, gathered but not rendered. The engine hands these to its
    /// reporter, and a server turns them into wire records.
    public struct Entry: Equatable {
        /// What to call the node in a log: `Type #id 'path'`. Sorts the report, and what the
        /// fold reads a type from.
        public let label:    String
        /// The node's type as a report names it: `SwiftCompiler`, or `kind 43` for a kind
        /// this server does not link.
        public let typeName: String
        /// The node, or the several of one type that carry one report (B-110).
        public let nodeIDs:  [ObjectID]
        public let items:    [Item]
        /// How many nodes downstream of this one fail only because this one did. They are
        /// folded into a count instead of a block each: one deleted header stops every node
        /// that reads it, and the reader can act on the header alone.
        public let downstreamCarrierCount: Int
        /// The products downstream of the node, in path order (B-142): what has no value
        /// because of it. Empty until `namingProducts` fills it, and empty after for a node
        /// nothing under `output:` reads or whose products were built anyway.
        public let products: [ProductReach.Product]

        public init(label: String, typeName: String, nodeIDs: [ObjectID], items: [Item],
                    downstreamCarrierCount: Int = 0, products: [ProductReach.Product] = []) {
            self.label                  = label
            self.typeName               = typeName
            self.nodeIDs                = nodeIDs
            self.items                  = items
            self.downstreamCarrierCount = downstreamCarrierCount
            self.products               = products
        }

        /// How many nodes the entry stands for.
        public var nodeCount: Int {
            nodeIDs.count
        }

        /// This entry with the products it stops.
        func naming(_ products: [ProductReach.Product]) -> Entry {
            Entry(label: label, typeName: typeName, nodeIDs: nodeIDs, items: items,
                  downstreamCarrierCount: downstreamCarrierCount, products: products)
        }
    }

    /// What to call a node in a log: `Type #id 'path'`, the form a `check` finding names
    /// it by, so that one node reads the same wherever the user meets it. A builder has no
    /// path of its own and is named by its project file.
    public static func label(forNodeID nodeID: ObjectID, database: DatabaseLayer) -> String {
        // A label for a report is best effort — the report must never fail — but a machine
        // failure on the way to it still reaches the fatal handler.
        guard let nodeRecord = FatalErrors.attempt({ try database.node.find(nodeID: nodeID) }) ?? nil else {
            return GraphCheck.subject(missingNodeID: nodeID)
        }
        return GraphCheck.subject(nodeRecord, path: path(of: nodeRecord, database: database))
    }

    /// The path a node is named by: its own when it has one, the project file it builds
    /// when it is a builder, nil when it is neither. Best effort, as the label is.
    public static func path(of nodeRecord: NodeRecord, database: DatabaseLayer) -> String? {
        if let path = nodeRecord.properties["path"] {
            return path
        }
        guard let nodeID = nodeRecord.id else {
            return nil
        }
        return FatalErrors.attempt({
            try database.wire.select(goingToNodeID: nodeID, toSymbolID: "projectFile".asSymbolID())
        })?.first?.name.resolveSymbol()
    }

    /// One node's errors: one item per distinct document, naming the ports carrying it.
    ///
    /// Grouped by document rather than by port, because a node that fails usually fails on
    /// all of its ports at once with the same document — gathering them onto one item says
    /// that once, where an item per port says the same thing three times and buries how
    /// many distinct problems there are.
    ///
    /// `documents` is the caller's selection. Passing fewer than the node has is how the
    /// engine reports only what is new.
    public static func entry(forNodeID nodeID: ObjectID,
                             ports: [OutputPort],
                             documents: Set<ErrorDocument>,
                             database: DatabaseLayer,
                             downstreamCarrierCount: Int = 0,
                             sourceDocuments: [ObjectID: ErrorDocument] = [:]) -> Entry {
        let items = documents.sorted(by: Self.documentOrder).map { document -> Item in
            // Matched by what each port reports rather than by what it stores, so that a
            // port whose state is its whole document is named alongside the rest.
            let portNames = ports
                .filter { self.document(of: $0, sourceDocuments: sourceDocuments) == document }
                .map { $0.nameSymbolID.resolveSymbol() }
                .sorted()
            return Item(ports: portNames, document: document)
        }
        let nodeRecord = FatalErrors.attempt({ try database.node.find(nodeID: nodeID) }) ?? nil
        return Entry(label: label(forNodeID: nodeID, database: database),
                     typeName: nodeRecord.map { GraphCheck.typeName(ofKind: $0.kind) } ?? "node",
                     nodeIDs: [nodeID],
                     items: items,
                     downstreamCarrierCount: downstreamCarrierCount)
    }

    /// One order for a node's documents, the same in every process: by their encoding,
    /// which sorts its keys.
    static func documentOrder(_ lhs: ErrorDocument, _ rhs: ErrorDocument) -> Bool {
        ((try? lhs.toJSON()) ?? "") < ((try? rhs.toJSON()) ?? "")
    }

    /// The document a port is carrying, or nil when it carries nothing worth reporting.
    ///
    /// Decided by the port's state. A port holding a value or waiting for one has no
    /// failure to report; neither has a port where no value has ever been produced, nor one
    /// whose node could not produce because of such a port — nothing has failed anywhere
    /// above either of them, and reporting the first would announce an error for every
    /// node in a fresh graph. A node that did not run because an input failed has no
    /// document of its own, so it reports the condition its state is. An error whose
    /// document cannot be read is still an error, and reported as one that cannot be read
    /// rather than dropped.
    ///
    /// A removed source reads as its state too. The document the report prefers names the
    /// path, which takes the graph around the port rather than the port alone, so this is
    /// what a caller without that reading falls back to.
    public static func reportableDocument(of port: OutputPort) -> ErrorDocument? {
        switch port.valueKind {
        case .value, .pending, .initializing, .inputNotProduced:
            return nil

        case .inputInError:
            return .engine(.inputInError, subject: nil)

        case .deleted:
            return .engine(.removed(path: nil, isFolder: false), subject: nil)

        case .error:
            let hash = port.dataObjectHash ?? ""
            return ErrorDocument.read(documentHash: hash) ?? .engine(.documentUnreadable(hash: hash), subject: nil)
        }
    }

    // MARK: - What a source's state reads as

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
    /// A source's state is not a document: it is the graph around it — a node with no
    /// inputs, a path the reader can type, and a consumer that needs what it does not have
    /// — that turns the state into one. This is that reading, for both of the states a
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
    /// graph's inputs, and it is the same block a reader needed when a removal broke a build.
    static func sourceDocuments(amongPorts ports: [OutputPort],
                                database: DatabaseLayer) -> [ObjectID: ErrorDocument] {

        var descriptors: [UInt: NodeDescriptor] = [:]
        var result: [ObjectID: ErrorDocument] = [:]

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
            // unnamed, which costs a block rather than printing a wrong one.
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

        var unpushed: [(nodeID: ObjectID, path: Path, isTree: Bool)] = []

        for port in ports where port.valueKind == .initializing || port.valueKind == .deleted {
            guard result[port.nodeID] == nil,
                  let record = FatalErrors.attempt({ try database.node.find(nodeID: port.nodeID) }) ?? nil,
                  let path = record.properties["path"] else {
                continue
            }
            let isTree = record.kind == Folder.kind

            // A removed source carries nothing a build follows: it went because someone took
            // it away, and a build that pushed it back would undo that unasked.
            if port.valueKind == .deleted {
                result[port.nodeID] = .engine(.removed(path: path, isFolder: isTree), subject: nil)
            } else if anythingNeeds(port.nodeID) {
                let writers = record.kind == StaticFile.kind
                    ? machineFileWriters(ofFileAt: path, nodeID: port.nodeID, database: database)
                    : []
                result[port.nodeID] = .engine(.notPushed(path: path, isFolder: isTree), subject: nil,
                                              remedy: writers.isEmpty ? nil : .writeMachineFile(commands: writers))
                unpushed.append((port.nodeID, Path(path), isTree))
            }
        }

        // A source under a folder that is itself unpushed and needed says nothing the
        // folder's block does not: pushing the folder pushes it. A converter waiting for a
        // package demands the package's folder and the reader of its `Package.swift` alike,
        // and the reader is the detail — one block, and one push, names the package (B-110).
        let unpushedFolders = unpushed.filter(\.isTree).map(\.path)
        for source in unpushed where unpushedFolders.contains(where: { source.path.count > $0.count && source.path.hasPrefix($0) }) {
            result[source.nodeID] = nil
        }

        return result
    }

    /// What writes a machine file nobody has pushed: the command each namespace selected
    /// out of it registered (B-109), with the folder the file sits in, relative to the
    /// input file system — `.` for its root — so a reader types it as the report prints it.
    /// Empty for a file of any other name — a writer writes `semel.machine.config` and
    /// nothing else, so it is no answer to a project's `semel.config` or a machine file a
    /// formula names otherwise.
    ///
    /// The namespaces are the prefixes of the `ConfigFilter`s the file's text reaches, down
    /// the wires through the `ConfigMerger`s between — a prelude lays the project's file
    /// over this one — which is the walk `unclaimedConfigKeys` makes. The engine names no
    /// toolchain: which command writes a namespace is what its plugin registered.
    static func machineFileWriters(ofFileAt path: String, nodeID: ObjectID, database: DatabaseLayer) -> [MachineFileCommand] {
        let full     = Path(path)
        let relative = full.relative(to: Path(FileSystemName.input)) ?? full
        guard relative.lastComponent == MachineFileWriter.fileName else {
            return []
        }

        var prefixes: Set<String> = []
        var pending:  [(producerID: ObjectID, port: String)] = [(nodeID, StaticFile.outputPort)]
        var seen:     Set<ObjectID> = [nodeID]

        while let (producerID, port) = pending.popLast() {
            // Best effort, as the rest of a report is: wires the database cannot hand over
            // leave the remedy out rather than name a wrong command.
            let wires = FatalErrors.attempt({
                try database.wire.select(comingFromNodeID: producerID, fromSymbolID: port.asSymbolID())
            }) ?? []
            for wire in wires where seen.insert(wire.toNodeID).inserted {
                guard let consumer = FatalErrors.attempt({ try database.node.find(nodeID: wire.toNodeID) }) ?? nil else {
                    continue
                }
                switch consumer.kind {
                case ConfigFilter.kind:
                    if let prefix = consumer.properties[ConfigFilter.prefixProperty] {
                        prefixes.insert(prefix)
                    }
                case ConfigMerger.kind:
                    pending.append((wire.toNodeID, ConfigMerger.outputPort))
                default:
                    continue
                }
            }
        }

        let folder = relative.deletingLastComponent?.string ?? "."
        var found: [MachineFileWriter] = []
        for prefix in prefixes.sorted() {
            if let writer = ToolNamespaceRegistry.entry(forNamespace: prefix)?.machineFileWriter, !found.contains(writer) {
                found.append(writer)
            }
        }
        return found.sorted().map { MachineFileCommand(writer: $0, folder: folder.isEmpty ? "." : folder) }
    }

    /// The document a port carries, with what the sources say already worked out.
    static func document(of port: OutputPort, sourceDocuments: [ObjectID: ErrorDocument]) -> ErrorDocument? {
        // A port that has never been processed says nothing by itself, so it has a document
        // only when the reading above gave it one.
        if port.valueKind == .initializing {
            return sourceDocuments[port.nodeID]
        }
        // A removed source always has one; naming its path is better than its state, and
        // the state is what is left when the node has no path.
        if port.valueKind == .deleted {
            return sourceDocuments[port.nodeID] ?? reportableDocument(of: port)
        }
        return reportableDocument(of: port)
    }

    /// What each node has to say, for a caller keeping track of what it has already said.
    ///
    /// `sourceDocuments` is a parameter so that a caller making several passes over one set
    /// of ports works the sources out once; leaving it out asks for them here.
    public static func documentsByNode(forPorts ports: [OutputPort],
                                       database: DatabaseLayer,
                                       sourceDocuments: [ObjectID: ErrorDocument]? = nil) -> [ObjectID: Set<ErrorDocument>] {
        let sourced = sourceDocuments ?? Self.sourceDocuments(amongPorts: ports, database: database)

        var result: [ObjectID: Set<ErrorDocument>] = [:]
        for port in ports {
            guard let document = document(of: port, sourceDocuments: sourced) else {
                continue
            }
            result[port.nodeID, default: []].insert(document)
        }
        return result
    }

    /// How many errors a set of entries is, as a report counts them: one per cause,
    /// merged as the client merges its blocks (`ErrorDocument.mergeKey`), so eight compilers
    /// missing one setting are one error. What the settle's summary says and what the
    /// report under it shows.
    public static func errorCount(of entries: [Entry]) -> Int {
        Set(entries.flatMap { $0.items.flatMap { $0.document.causes.map(\.mergeKey) } }).count
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
               sourceDocuments: sourceDocuments(amongPorts: byNode.values.flatMap { $0 }, database: database))
    }

    static func causes(amongErrorPorts byNode: [ObjectID: [OutputPort]],
                       database: DatabaseLayer,
                       sourceDocuments: [ObjectID: ErrorDocument]) -> [ObjectID: Int] {

        var reporting: [ObjectID: [OutputPort]] = [:]
        for (nodeID, ports) in byNode {
            let listed = ports.filter {
                document(of: $0, sourceDocuments: sourceDocuments) != nil || isCarriedFromAnAbsentInput($0)
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
            // carrier standing in for its own cause, which is still one block rather than none.
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
    /// one node's documents to the ones that caller wants — the engine to what is newly
    /// appearing, the verb to everything. A node left with nothing is not reported.
    ///
    /// `sourceDocuments` is a parameter for the same reason it is one on `documentsByNode`:
    /// the engine makes three passes over one idle pass's ports and works the sources out
    /// once.
    public static func entries(forErrorPorts errorPorts: [OutputPort],
                               database: DatabaseLayer,
                               sourceDocuments: [ObjectID: ErrorDocument]? = nil,
                               select: (ObjectID, Set<ErrorDocument>) -> Set<ErrorDocument>) -> [Entry] {

        let byNode  = Dictionary(grouping: errorPorts, by: \.nodeID)
        let sourced = sourceDocuments ?? Self.sourceDocuments(amongPorts: errorPorts, database: database)
        let counts  = causes(amongErrorPorts: byNode, database: database, sourceDocuments: sourced)

        var reported: [Entry] = []

        for (nodeID, carriedCount) in counts {
            let ports    = byNode[nodeID] ?? []
            let selected = select(nodeID, Set(ports.compactMap { document(of: $0, sourceDocuments: sourced) }))
            guard !selected.isEmpty else {
                continue
            }

            reported.append(entry(forNodeID: nodeID,
                                  ports: ports,
                                  documents: selected,
                                  database: database,
                                  downstreamCarrierCount: carriedCount,
                                  sourceDocuments: sourced))
        }

        return fold(reported)
    }

    /// The same entries, each with the products downstream of the nodes it stands for
    /// (B-142), through one walk: the cascade under one product is walked once however
    /// many entries share it. A separate step from `entries` because only a report that is
    /// sent wants it — the settle's error count is the same fold and names nothing.
    public static func namingProducts(of reported: [Entry], reach: inout ProductReach) -> [Entry] {
        reported.map { entry in
            entry.naming(reach.products(downstreamOf: entry.nodeIDs))
        }
    }

    /// Nodes of one type carrying one report are one entry, named together: eight
    /// compilers each missing the same four settings are one entry that says which eight,
    /// not eight (B-110). Only a node named by type and id alone folds — a node with a path
    /// is one the reader acts on by that path, and two of them never carry one report
    /// anyway, since the report names the path.
    ///
    /// Sorted by label and then by node, so a report reads the same from run to run: the
    /// error map is a dictionary, whose order is seeded per process. The id is left out of
    /// the label the sort reads and kept as the tie break: compared as text it puts `#10`
    /// before `#9`, and it would order a folder's files by when their nodes were made
    /// rather than by their paths.
    static func fold(_ reported: [Entry]) -> [Entry] {
        struct Key: Hashable {
            let type:  String
            let items: [Item]
        }
        var singles: [(sortKey: String, entry: Entry)] = []
        var groups:  [Key: [Entry]] = [:]

        for entry in reported {
            let label  = entry.label
            let nodeID = entry.nodeIDs.first ?? 0
            guard !label.contains(" '"), label.contains(" #") else {
                singles.append((label.replacingOccurrences(of: " #\(nodeID)", with: ""), entry))
                continue
            }
            groups[Key(type: entry.typeName, items: entry.items), default: []].append(entry)
        }

        for (key, members) in groups.sorted(by: { ($0.value.first?.nodeIDs.first ?? 0) < ($1.value.first?.nodeIDs.first ?? 0) }) {
            let ordered = members.sorted { ($0.nodeIDs.first ?? 0) < ($1.nodeIDs.first ?? 0) }
            guard ordered.count > 1 else {
                singles.append(contentsOf: ordered.map { (key.type, $0) })
                continue
            }
            let ids = ordered.flatMap(\.nodeIDs)
            singles.append((key.type,
                            Entry(label: "\(key.type) ×\(ordered.count) (\(ids.map { "#\($0)" }.joined(separator: ", ")))",
                                  typeName: key.type,
                                  nodeIDs: ids,
                                  items: key.items,
                                  downstreamCarrierCount: ordered.reduce(0) { $0 + $1.downstreamCarrierCount })))
        }

        return singles
            .sorted { ($0.sortKey, $0.entry.nodeIDs.first ?? 0) < ($1.sortKey, $1.entry.nodeIDs.first ?? 0) }
            .map(\.entry)
    }
}
