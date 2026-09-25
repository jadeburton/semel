// GraphCheck.swift
// SemelCore
//
// The invariants the graph is supposed to hold, asked of every row rather than waited for.
//
// Each one of these has been broken by a real defect and found by a test written after the
// symptom: a wire dropped because two shared a key, a folder manifest rebuilt per child, an
// error whose message was empty. Nothing in the running system could say any of it about
// itself, because every one of these states is silent — a product whose required input has
// no wire holds `initializing`, which is a state and not a failure, and the prompt is
// correct to say nothing about it.
//
// This reports and repairs nothing. `reset` is the repair; a finding is how one learns
// whether it is needed and what to file when it is. It follows that nothing here may write:
// no `asSymbolID()`, which interns, and no `makeNode()`, which places a node in the file
// system and force-unwraps properties a broken row may not have. A check run over a graph
// that is already wrong must not be a second way for it to go wrong.
//
// It is meant for a settled graph. The whole walk happens inside one read, so it can never
// see half of one change; what it cannot see is a change the engine has yet to make, and a
// node whose wires are still being built looks, for that moment, exactly like a node whose
// wires are missing. The report carries the count of scheduled nodes so a reader is told
// when that is the case, rather than being made to wait for a graph that may be stuck.

import SemelDatabaseModels
import SemelNodeKit

/// Every invariant that does not hold, as sentences about the node or wire each concerns.
public struct GraphCheck {

    /// What kind of invariant a finding is about. The reader classifies by this and never
    /// by the sentence, which is written for a person.
    public enum Kind: String, Equatable, Sendable {
        /// A wire whose endpoint node, or whose port on one of them, is gone.
        case danglingWire
        /// A node holding no row for an output port its type declares. Every node is given
        /// one per declared port when it is created, so a missing row is a node something
        /// has damaged, and a read of that port has nothing true to answer.
        case missingOutputPort
        /// A node whose `graphSpec` cannot be read back, or which has none at all.
        case unreadableGraphSpec
        /// A node whose `graphSpec` names a type this server does not link.
        case unlinkedNodeType
        /// A required input port with no wire: nothing will ever produce what it asks for.
        case productWithNoProducer
        /// A folder manifest and the folder's children disagreeing, either way round.
        case missingManifestChild
        /// A port in error carrying no message, or one whose message cannot be read —
        /// between them, the failures a reader cannot diagnose.
        case errorWithoutMessage
        /// A cache entry whose key is not of the shape a key is written in.
        case unreadableCacheKey
        /// Part of the graph could not be read at all, so this walk is incomplete. Not an
        /// invariant of the graph but a fact about the answer, and a finding for the same
        /// reason the others are: silence would read as a clean bill of health.
        case graphCouldNotBeRead
    }

    /// One invariant that does not hold: what kind it is, what it is about, and what is
    /// wrong in one sentence.
    public struct Finding: Equatable, Sendable {
        public let kind:     Kind
        /// The node or the wire this concerns, named so it can be found again.
        public let subject:  String
        public let sentence: String

        public init(kind: Kind, subject: String, sentence: String) {
            self.kind     = kind
            self.subject  = subject
            self.sentence = sentence
        }
    }

    /// What one walk of the graph came to.
    ///
    /// `scheduledNodeCount` travels with the findings because it is what decides how to
    /// read them: on a settled graph a finding is a defect, and on a graph with work still
    /// in flight a finding about wiring may be describing a node the engine has not
    /// finished building. Counted from the same snapshot as the findings, so the two
    /// cannot disagree, and carried rather than acted on — nothing here gates or waits.
    public struct Report: Equatable, Sendable {
        public let findings:           [Finding]
        public let scheduledNodeCount: Int

        public init(findings: [Finding], scheduledNodeCount: Int) {
            self.findings           = findings
            self.scheduledNodeCount = scheduledNodeCount
        }
    }

    /// Walks the graph and answers everything that does not hold, in a fixed order so two
    /// runs over one graph read the same.
    ///
    /// **Ask this of a settled graph.** Every query runs inside one read, so the walk sees
    /// one state and cannot manufacture a finding out of two; but a node the engine is
    /// still wiring is a node whose wires are genuinely absent at the moment it is looked
    /// at, and `productWithNoProducer` and `danglingWire` are the two that say so. The
    /// report's `scheduledNodeCount` is how a caller tells the reader which graph it was.
    ///
    /// Does not throw, and never answers an empty report it cannot stand behind. A table
    /// it cannot read costs that table's findings rather than the whole report — but the
    /// failure itself is reported, as `graphCouldNotBeRead`, because a check that could
    /// not look is not a check that found nothing. The machine's own failures still reach
    /// the fatal handler through `FatalErrors.attempt` on the way.
    public static func run(database: DatabaseLayer) -> Report {
        // One read for the whole walk. Outside one, the nodes and the wires are two states:
        // a node created between the two scans leaves a wire that appears to point at
        // nothing, which is a finding against a graph that is perfectly sound.
        FatalErrors.attempt { try database.withReadSnapshot { walk(database: database) } }
            // The read itself failed, so not one question was asked. Under the default
            // fatal handler this is unreachable — it stops the process — but a server that
            // installs its own gets here, and must not be told the graph is clean.
            ?? Report(findings: [Finding(kind: .graphCouldNotBeRead, subject: "the graph database",
                                         sentence: "it could not be read, so nothing was checked")],
                      scheduledNodeCount: 0)
    }

    /// A check whose prerequisite table could not be read does not run at all.
    ///
    /// An empty table and an unreadable one look alike from inside a check, and every
    /// answer that follows is wrong in the same direction: with no nodes, every wire is
    /// dangling; with no wires, every required port is unproduced; with no metadata, every
    /// folder awaiting a rebuild is a folder whose manifest disagrees. One unreadable
    /// table would become a finding per row, burying the one line that says what actually
    /// happened — so the checks it carries are skipped, and that line says which.
    private static func walk(database: DatabaseLayer) -> Report {
        let context = Context(database: database)

        var findings: [Finding] = []
        if context.canRun(.nodes, .wires)    { findings += danglingWires(context) }
        if context.canRun(.nodes)            { findings += missingOutputPorts(context) }
        if context.canRun(.nodes)            { findings += graphSpecs(context) }
        if context.canRun(.nodes, .wires)    { findings += productsWithNoProducer(context) }
        if context.canRun(.nodes, .metadata) { findings += folderManifests(context) }
        // Neither of these rests on a table another check needs: a port in error says so
        // by itself, and a cache key is a string in a column of its own. A node table the
        // walk could not read costs the first its labels, not its findings.
        if context.canRun(.nodes)            { findings += errorPortsWithoutMessages(context) }
        findings += cacheKeys(context)

        findings.sort { ($0.kind.rawValue, $0.subject, $0.sentence)
                      < ($1.kind.rawValue, $1.subject, $1.sentence) }

        // Ahead of the rest rather than sorted among them: what the walk could not look at
        // is what the rest of the report has to be read against, so it goes first whatever
        // its kind sorts as.
        return Report(findings: context.unreadableFindings + findings,
                      scheduledNodeCount: context.nodes.filter(\.scheduled).count)
    }

    // MARK: - What every check reads

    /// The rows every check works from, read once, and the name lookups they share.
    ///
    /// A class rather than a struct because it memoises: a port name resolved for one wire
    /// is the same name for the next thousand, and the check was otherwise three symbol
    /// queries per wire. Single-threaded by construction — one `run`, one instance, never
    /// escaping the walk — so the caches need no lock.
    /// A table the walk reads before any check runs, and the checks that cannot answer
    /// without it. Read up front precisely so that a check knows whether to run at all,
    /// rather than discovering it half way through a loop.
    private enum Prerequisite: String {
        case nodes    = "the node table"
        case wires    = "the wire table"
        case metadata = "the metadata table"

        /// What is not asked when this cannot be read, in the words a reader knows the
        /// checks by.
        var checksItCarries: [String] {
            switch self {
            case .nodes:    return ["wires", "output ports", "graph specs", "products", "folder manifests",
                                    "error ports"]
            case .wires:    return ["wires", "products"]
            case .metadata: return ["folder manifests"]
            }
        }
    }

    private final class Context {
        let database:  DatabaseLayer
        var nodes:     [NodeRecord] = []
        var nodesByID: [ObjectID: NodeRecord] = [:]
        var wires:     [Wire] = []
        /// Folders whose manifest is waiting to be rebuilt, which is the engine working as
        /// designed. Read with the rest, so `metadata` being unreadable is known before
        /// the manifest check would otherwise report every pending folder.
        var dirtyFolderIDs: Set<ObjectID> = []

        /// What the walk asked for and did not get, named once however many rows wanted
        /// it. A set, because a point query that fails for one row fails for every row,
        /// and a report of one damaged table should not be ten thousand lines.
        private(set) var unreadable: Set<String> = []

        private var namesBySymbolID: [ObjectID: String] = [:]
        private var symbolIDsByName: [String: ObjectID?] = [:]

        init(database: DatabaseLayer) {
            self.database = database
            nodes = read(Prerequisite.nodes.rawValue) { try database.node.selectAll() } ?? []
            wires = read(Prerequisite.wires.rawValue) { try database.wire.selectAll() } ?? []
            nodesByID = Dictionary(nodes.compactMap { node in node.id.map { ($0, node) } },
                                   uniquingKeysWith: { first, _ in first })

            let dirtyKeys = read(Prerequisite.metadata.rawValue) {
                try database.metadata.selectKeys(withPrefix: Folder.manifestDirtyKeyPrefix)
            } ?? []
            dirtyFolderIDs = Set(dirtyKeys.compactMap { ObjectID($0.dropFirst(Folder.manifestDirtyKeyPrefix.count)) })
        }

        /// A list as a sentence says it: commas between, "and" before the last. A finding
        /// is prose a person reads, not a field a machine splits.
        private func listed(_ items: [String]) -> String {
            guard let last = items.last, items.count > 1 else {
                return items.first ?? ""
            }
            return items.dropLast().joined(separator: ", ") + " and " + last
        }

        /// Whether every table a check rests on was readable.
        func canRun(_ prerequisites: Prerequisite...) -> Bool {
            !prerequisites.contains { unreadable.contains($0.rawValue) }
        }

        /// One finding per thing the walk could not read, in a fixed order. A table some
        /// check rests on says which checks went unasked, so a short report is not mistaken
        /// for a short list of problems.
        var unreadableFindings: [Finding] {
            unreadable.sorted().map { what in
                guard let prerequisite = Prerequisite(rawValue: what) else {
                    return Finding(kind: .graphCouldNotBeRead, subject: what,
                                   sentence: "it could not be read, so whatever it had to say is "
                                           + "missing from this report")
                }
                return Finding(kind: .graphCouldNotBeRead, subject: what,
                               sentence: "it could not be read, so "
                                       + listed(prerequisite.checksItCarries)
                                       + " were not checked")
            }
        }

        /// One read, with `what` recorded when it fails. Every query the walk makes goes
        /// through here, so nothing the database refuses can leave the report looking
        /// clean. The machine's own failures still reach the fatal handler first.
        func read<T>(_ what: String, _ work: () throws -> T) -> T? {
            guard let value = FatalErrors.attempt(work) else {
                unreadable.insert(what)
                return nil
            }
            return value
        }

        /// A symbol's text, through the table rather than through `resolveSymbol()`: an id
        /// with no row is one of the states this is here to find, and resolving it would
        /// stop the process instead of reporting it.
        func name(ofSymbol symbolID: ObjectID) -> String {
            if let known = namesBySymbolID[symbolID] {
                return known
            }
            let symbol = read("the symbol table") { try database.symbol.select(symbolID: symbolID) } ?? nil
            let name = symbol?.name ?? "#\(symbolID)"
            namesBySymbolID[symbolID] = name
            return name
        }

        /// A name's symbol id, or nil when the table does not hold it. Through the table
        /// rather than `asSymbolID()`, which interns — and a name the table does not hold
        /// is a name no wire can be carrying either, so nil is an answer and not a gap.
        func symbolID(ofName name: String) -> ObjectID? {
            if let known = symbolIDsByName[name] {
                return known
            }
            let id = read("the symbol table") { try database.symbol.selectID(name: name) } ?? nil
            symbolIDsByName[name] = id
            return id
        }
    }

    // MARK: - Naming what a finding is about

    /// What to call a node: its type, its id, and its path when it has one. The id is in
    /// every subject rather than kept as a last resort — a finding is filed as a bug, and
    /// the row is what the next person has to look at. `ErrorReport.label` names a node
    /// this way too, passing the path it found when the node has none of its own.
    static func subject(_ node: NodeRecord, path: String?) -> String {
        var name = "\(typeName(ofKind: node.kind)) #\(node.id ?? -1)"
        if let path {
            name += " '\(path)'"
        }
        return name
    }

    /// What to call a node that has no row.
    static func subject(missingNodeID nodeID: ObjectID) -> String {
        "node #\(nodeID)"
    }

    private static func subject(_ node: NodeRecord) -> String {
        subject(node, path: node.properties["path"])
    }

    private static func subject(nodeID: ObjectID, in context: Context) -> String {
        guard let node = context.nodesByID[nodeID] else {
            return subject(missingNodeID: nodeID)
        }
        return subject(node)
    }

    private static func subject(_ wire: Wire, in context: Context) -> String {
        "wire '\(context.name(ofSymbol: wire.name))' "
            + "from #\(wire.fromNodeID).\(context.name(ofSymbol: wire.fromSymbolID)) "
            + "to #\(wire.toNodeID).\(context.name(ofSymbol: wire.toSymbolID))"
    }

    /// The Swift type a kind stands for, or the number when this server links no such type.
    private static func typeName(ofKind kind: UInt) -> String {
        guard let type = try? TypeRegistry.type(kind: kind) else {
            return "kind \(kind)"
        }
        return String(describing: type)
    }

    /// The ports a kind declares, or nil when this server links no such type — which is
    /// `unlinkedNodeType`'s finding to report, not this one's.
    private static func descriptor(ofKind kind: UInt) -> NodeDescriptor? {
        guard let type = try? TypeRegistry.type(kind: kind), let nodeType = type as? Node.Type else {
            return nil
        }
        return nodeType.descriptor
    }

    // MARK: - A wire whose endpoint node or port is gone

    /// Both ends of every wire, and both ports. A wire is the graph's only structure, so a
    /// wire into nothing is a node that will never be scheduled and a build that stops
    /// without saying why.
    private static func danglingWires(_ context: Context) -> [Finding] {
        var findings: [Finding] = []

        for wire in context.wires {
            guard let fromNode = context.nodesByID[wire.fromNodeID] else {
                findings.append(Finding(kind: .danglingWire, subject: subject(wire, in: context),
                                        sentence: "the node it comes from, #\(wire.fromNodeID), does not exist"))
                continue
            }
            guard let toNode = context.nodesByID[wire.toNodeID] else {
                findings.append(Finding(kind: .danglingWire, subject: subject(wire, in: context),
                                        sentence: "the node it goes to, #\(wire.toNodeID), does not exist"))
                continue
            }

            // The from-port is asked both questions: whether its row is there, and whether
            // the type declares it. A port dropped from a type leaves its row behind, and
            // the row alone would pass a wire that nothing will ever write to again.
            let fromPortName = context.name(ofSymbol: wire.fromSymbolID)
            let fromPort = context.read("the output-port table") {
                try context.database.outputPort.select(nodeID: wire.fromNodeID, nameSymbolID: wire.fromSymbolID)
            } ?? nil
            if fromPort == nil {
                findings.append(Finding(kind: .danglingWire, subject: subject(wire, in: context),
                                        sentence: "\(Self.subject(fromNode)) has no output port '\(fromPortName)'"))
            } else if let descriptor = descriptor(ofKind: fromNode.kind),
                      !descriptor.outputPorts.contains(fromPortName) {
                findings.append(Finding(kind: .danglingWire, subject: subject(wire, in: context),
                                        sentence: "\(Self.subject(fromNode)) declares no output port '\(fromPortName)'"))
            }

            // Only when the type is linked: a node whose type is gone declares no ports at
            // all, and reporting every wire into it would bury the one finding that says so.
            let toPortName = context.name(ofSymbol: wire.toSymbolID)
            if let descriptor = descriptor(ofKind: toNode.kind),
               !descriptor.inputPorts.contains(where: { $0.name == toPortName }) {
                findings.append(Finding(kind: .danglingWire, subject: subject(wire, in: context),
                                        sentence: "\(Self.subject(toNode)) declares no input port '\(toPortName)'"))
            }
        }

        return findings
    }

    // MARK: - A port its type declares and the node holds no row for

    /// Every output port a linked type declares, against the rows its node holds. A node
    /// is given one row per declared port when it is created, and only its own deletion
    /// takes them away — so a declared port with no row is a node something damaged, and
    /// a read of that port has no value, no state and no message to answer with.
    ///
    /// Only when the type is linked, for the reason `danglingWires` gives: a node whose
    /// type is gone declares no ports, and `unlinkedNodeType` is the finding that says so.
    private static func missingOutputPorts(_ context: Context) -> [Finding] {
        var findings: [Finding] = []

        for node in context.nodes {
            guard let nodeID = node.id, let descriptor = descriptor(ofKind: node.kind),
                  let rows = (context.read("the output-port table") {
                      try context.database.outputPort.selectAll(nodeID: nodeID)
                  }) else {
                continue
            }
            let heldSymbolIDs = Set(rows.map(\.nameSymbolID))
            for portName in descriptor.outputPorts {
                if let symbolID = context.symbolID(ofName: portName), heldSymbolIDs.contains(symbolID) {
                    continue
                }
                findings.append(Finding(kind: .missingOutputPort, subject: subject(node),
                                        sentence: "its type declares the output port '\(portName)', "
                                                + "and it holds no row for it"))
            }
        }

        return findings
    }

    // MARK: - A graph spec that cannot be read back, or names a type the server does not link

    /// A node's `graphSpec` is its identity: it is what `findOrCreateMatchingNode` matches
    /// against, so a spec that cannot be read back is a node nothing will ever find again,
    /// and one naming an absent type is a node nothing can rebuild.
    ///
    /// A node with no spec at all is the same defect in its plainest form. The column is
    /// nullable only because a row exists for a moment before its spec is patched in, and
    /// `createNode` asserts one is there by the time it returns — so a NULL that survives
    /// is a node the matcher can never reach.
    private static func graphSpecs(_ context: Context) -> [Finding] {
        var findings: [Finding] = []

        for node in context.nodes {
            guard let graphSpec = node.graphSpec else {
                findings.append(Finding(kind: .unreadableGraphSpec, subject: subject(node),
                                        sentence: "it has no graph spec, so nothing can match it again"))
                continue
            }
            let spec: GraphSpecNode
            do {
                spec = try GraphSpecNode.parse(graphSpec)
            } catch {
                findings.append(Finding(kind: .unreadableGraphSpec, subject: subject(node),
                                        sentence: "its graph spec cannot be read back — \(error)"))
                continue
            }
            if TypeRegistry.nodeType(forTypeName: spec.typeName) == nil {
                findings.append(Finding(kind: .unlinkedNodeType, subject: subject(node),
                                        sentence: "its graph spec names the type '\(spec.typeName)', "
                                                + "which this server does not link"))
            }
        }

        return findings
    }

    // MARK: - A product with no producer

    /// A required input port with no wire on it. This is the one the prompt cannot report
    /// on its own: the port holds `initializing`, which is a state and not a failure, and
    /// the engine's inconsistent-input catch is a not-ready signal rather than an error, so
    /// an `OutputFile` nothing produces waits forever and says nothing.
    ///
    /// The applier validates only the ports a spec names, so a required port the spec never
    /// mentions is checked nowhere else. It is also the finding most worth reading beside
    /// the scheduled count: a node the engine is still wiring has no wire on it yet either.
    private static func productsWithNoProducer(_ context: Context) -> [Finding] {
        let wiredPorts = Set(context.wires.map { WiredPort(nodeID: $0.toNodeID, symbolID: $0.toSymbolID) })

        var findings: [Finding] = []

        for node in context.nodes {
            guard let nodeID = node.id, let descriptor = descriptor(ofKind: node.kind) else {
                continue
            }
            for portName in descriptor.requiredInputPorts {
                if let symbolID = context.symbolID(ofName: portName),
                   wiredPorts.contains(WiredPort(nodeID: nodeID, symbolID: symbolID)) {
                    continue
                }
                findings.append(Finding(kind: .productWithNoProducer, subject: subject(node),
                                        sentence: "nothing is wired to its required input port "
                                                + "'\(portName)', so it can never be produced"))
            }
        }

        return findings
    }

    /// One end of a wire, as a key. A tuple is not `Hashable`, and the set is what keeps
    /// this check one pass over the wires rather than one query per required port.
    private struct WiredPort: Hashable {
        let nodeID:   ObjectID
        let symbolID: ObjectID
    }

    // MARK: - A folder manifest disagreeing with the folder

    /// A folder's manifest and its children say the same thing, both ways round.
    /// `buildManifest` emits exactly one entry per child row, so a name in the manifest
    /// that no child answers to and a child the manifest does not name are the same
    /// invariant seen from its two ends — and the second is the one a manifest left stale
    /// produces, which is the defect this check was written for.
    ///
    /// A folder marked dirty is passed over: its manifest is waiting to be rebuilt, which
    /// is the engine working as designed and not an invariant that does not hold. The
    /// rebuild is deliberately not triggered here — reading a port must not be what repairs
    /// it, in the one command that repairs nothing.
    private static func folderManifests(_ context: Context) -> [Finding] {
        var childNames: [ObjectID: Set<String>] = [:]
        for node in context.nodes {
            guard let parentNodeID = node.parentNodeID, let name = node.name else {
                continue
            }
            childNames[parentNodeID, default: []].insert(name)
        }

        // One lookup for every folder, rather than one per folder: the port's name is the
        // same string each time round.
        let manifestSymbolID = context.symbolID(ofName: Folder.folderManifestOutputPort)

        var findings: [Finding] = []

        for node in context.nodes where node.kind == Folder.kind {
            guard let nodeID = node.id, !context.dirtyFolderIDs.contains(nodeID), let manifestSymbolID,
                  let manifest = readManifest(ofFolder: nodeID, nameSymbolID: manifestSymbolID, in: context) else {
                continue
            }
            let children = childNames[nodeID] ?? []
            let named    = Set(manifest.entries.map(\.name))

            for name in named.subtracting(children).sorted() {
                findings.append(Finding(kind: .missingManifestChild, subject: subject(node),
                                        sentence: "its manifest names the child '\(name)', which does not exist"))
            }
            for name in children.subtracting(named).sorted() {
                findings.append(Finding(kind: .missingManifestChild, subject: subject(node),
                                        sentence: "the child '\(name)' exists, and its manifest does not name it"))
            }
        }

        return findings
    }

    /// The manifest a folder is publishing, or nil when it is not publishing one — a
    /// folder whose port holds a state rather than a value has nothing to disagree with.
    private static func readManifest(ofFolder nodeID: ObjectID,
                                     nameSymbolID: ObjectID,
                                     in context: Context) -> FolderManifest? {
        guard let port = (context.read("the output-port table") {
                  try context.database.outputPort.select(nodeID: nodeID, nameSymbolID: nameSymbolID)
              } ?? nil),
              port.valueKind == .value,
              let json = try? port.dataObjectHash?.resolveAsString() else {
            return nil
        }
        return try? TypeRegistry.decodeAndCast(encodedJSON: json)
    }

    // MARK: - An error port with no message, or none that can be read

    /// An error carrying nothing is the one failure a reader cannot act on: the report
    /// prints "an error with no message" and there is nowhere further to go. The node that
    /// wrote it is the bug, and this is what names it.
    ///
    /// An error whose message is *stored* but cannot be read is a different and worse
    /// defect — the object store has lost the bytes — so it is said differently. Both are
    /// decided by the port's state and by whether an object resolves, never by what a
    /// message says.
    private static func errorPortsWithoutMessages(_ context: Context) -> [Finding] {
        let errorPorts = context.read("the output-port table") { try ErrorReport.portsToReport(database: context.database) } ?? []

        // By case, not by text: a port carrying an input's failure, and one carrying a
        // source that was removed, have no message of their own and are not supposed to.
        // Only a node that failed and said nothing is the defect this names.
        return errorPorts.filter { $0.valueKind == .error }.compactMap { port in
            let portName = context.name(ofSymbol: port.nameSymbolID)
            switch message(of: port) {
            case .text:
                return nil
            case .absent:
                return Finding(kind: .errorWithoutMessage,
                               subject: subject(nodeID: port.nodeID, in: context),
                               sentence: "its port '\(portName)' is in error with no message, "
                                       + "so nothing says what failed")
            case .unreadable:
                return Finding(kind: .errorWithoutMessage,
                               subject: subject(nodeID: port.nodeID, in: context),
                               sentence: "its port '\(portName)' is in error and its message cannot be "
                                       + "read back from the object store, so what failed is lost")
            }
        }
    }

    /// What a port in error has to say for itself: words, nothing at all, or an object it
    /// names that will not come back.
    private enum PortMessage {
        case text
        case absent
        case unreadable
    }

    private static func message(of port: OutputPort) -> PortMessage {
        guard let hash = port.dataObjectHash, !hash.isEmpty else {
            return .absent
        }
        guard let text = try? hash.resolveAsString() else {
            return .unreadable
        }
        return text.isEmpty ? .absent : .text
    }

    // MARK: - A cache entry whose key is not the shape a key has

    /// A cache key is the hex of a hash and has no other shape, so there is nothing to
    /// parse beyond that. One that is not says the row was written by something other than
    /// `Cache.buildCacheKeyFromAllInputs`, and a key that cannot be recomputed is an entry
    /// nothing will ever hit again.
    ///
    /// What this cannot see is a well-formed key whose *content* is stale — an entry
    /// computed by a Semel that would compute a different one from the same inputs. That is
    /// B-102's ground: the key would have to carry the code's version to catch it.
    private static func cacheKeys(_ context: Context) -> [Finding] {
        let hashes = context.read("the cache table") { try context.database.cacheEntry.selectAllHashes() } ?? []

        return hashes.filter { !isHexadecimal($0) }.map { hash in
            Finding(kind: .unreadableCacheKey, subject: "cache entry '\(hash)'",
                    sentence: "its key is not the hexadecimal of a hash, so nothing can produce it again")
        }
    }

    /// Whether a string is what `Sha256.hash` writes: a non-empty, even-length run of
    /// lowercase hex digits.
    private static func isHexadecimal(_ string: String) -> Bool {
        !string.isEmpty
            && string.count.isMultiple(of: 2)
            && string.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
