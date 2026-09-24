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

import SemelDatabaseModels
import SemelNodeKit

/// Every invariant that does not hold, as sentences about the node or wire each concerns.
public struct GraphCheck {

    /// What kind of invariant a finding is about. The reader classifies by this and never
    /// by the sentence, which is written for a person.
    public enum Kind: String, Equatable, Sendable {
        /// A wire whose endpoint node, or whose port on one of them, is gone.
        case danglingWire
        /// A node whose `graphSpec` cannot be read back.
        case unreadableGraphSpec
        /// A node whose `graphSpec` names a type this server does not link.
        case unlinkedNodeType
        /// A required input port with no wire: nothing will ever produce what it asks for.
        case productWithNoProducer
        /// A folder manifest naming a child that does not exist.
        case missingManifestChild
        /// A port in error carrying no message, which is the one failure a reader cannot
        /// diagnose.
        case errorWithoutMessage
        /// A cache entry whose key is not of the shape a key is written in.
        case unreadableCacheKey
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

    /// Walks the graph and answers everything that does not hold, in a fixed order so two
    /// runs over one graph read the same.
    ///
    /// Does not throw. A check is asked for when something is already wrong, so a table it
    /// cannot read costs its own findings and not the report: the machine's own failures
    /// still reach the fatal handler through `FatalErrors.attempt`.
    public static func run(database: DatabaseLayer) -> [Finding] {
        let context = Context(database: database)

        var findings: [Finding] = []
        findings += danglingWires(context)
        findings += graphSpecs(context)
        findings += productsWithNoProducer(context)
        findings += folderManifests(context)
        findings += errorPortsWithoutMessages(context)
        findings += cacheKeys(context)

        return findings.sorted { ($0.kind.rawValue, $0.subject, $0.sentence)
                               < ($1.kind.rawValue, $1.subject, $1.sentence) }
    }

    // MARK: - What every check reads

    /// The rows every check works from, read once. Six passes over a graph of any size
    /// would otherwise be six full scans each.
    private struct Context {
        let database:  DatabaseLayer
        let nodes:     [NodeRecord]
        let nodesByID: [ObjectID: NodeRecord]
        let wires:     [Wire]

        init(database: DatabaseLayer) {
            self.database = database
            nodes = FatalErrors.attempt { try database.node.selectAll() } ?? []
            wires = FatalErrors.attempt { try database.wire.selectAll() } ?? []
            nodesByID = Dictionary(nodes.compactMap { node in node.id.map { ($0, node) } },
                                   uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: - Naming what a finding is about

    /// What to call a node: its type, its id, and its path when it has one. The id is in
    /// every subject rather than kept as a last resort — a finding is filed as a bug, and
    /// the row is what the next person has to look at.
    private static func subject(_ node: NodeRecord) -> String {
        var name = "\(typeName(ofKind: node.kind)) #\(node.id ?? -1)"
        if let path = node.properties["path"] {
            name += " '\(path)'"
        }
        return name
    }

    private static func subject(nodeID: ObjectID, in context: Context) -> String {
        guard let node = context.nodesByID[nodeID] else {
            return "node #\(nodeID)"
        }
        return subject(node)
    }

    private static func subject(_ wire: Wire, in context: Context) -> String {
        "wire '\(name(ofSymbol: wire.name, in: context))' "
            + "from #\(wire.fromNodeID).\(name(ofSymbol: wire.fromSymbolID, in: context)) "
            + "to #\(wire.toNodeID).\(name(ofSymbol: wire.toSymbolID, in: context))"
    }

    /// The Swift type a kind stands for, or the number when this server links no such type.
    private static func typeName(ofKind kind: UInt) -> String {
        guard let type = try? TypeRegistry.type(kind: kind) else {
            return "kind \(kind)"
        }
        return String(describing: type)
    }

    /// A symbol's text, through the table rather than through `resolveSymbol()`: an id with
    /// no row is one of the states this is here to find, and resolving it would stop the
    /// process instead of reporting it.
    private static func name(ofSymbol symbolID: ObjectID, in context: Context) -> String {
        guard let symbol = FatalErrors.attempt({ try context.database.symbol.select(symbolID: symbolID) }) ?? nil else {
            return "#\(symbolID)"
        }
        return symbol.name
    }

    /// The ports a kind declares, or nil when this server links no such type — which is
    /// `unlinkedNodeType`'s finding to report, not this one's.
    private static func descriptor(ofKind kind: UInt) -> NodeDescriptor? {
        guard let type = try? TypeRegistry.type(kind: kind), let nodeType = type as? Node.Type else {
            return nil
        }
        return nodeType.descriptor
    }

    /// The text a port in error is carrying, empty when it carries none or when the object
    /// it names cannot be read — both of which leave a reader with nothing.
    private static func message(of port: OutputPort) -> String {
        guard let hash = port.dataObjectHash else {
            return ""
        }
        return (try? hash.resolveAsString()) ?? ""
    }

    // MARK: - A wire whose endpoint node or port is gone

    /// Both ends of every wire, and both ports. A wire is the graph's only structure, so a
    /// wire into nothing is a node that will never be scheduled and a build that stops
    /// without saying why.
    private static func danglingWires(_ context: Context) -> [Finding] {
        var findings: [Finding] = []

        for wire in context.wires {
            let subject = subject(wire, in: context)

            guard let fromNode = context.nodesByID[wire.fromNodeID] else {
                findings.append(Finding(kind: .danglingWire, subject: subject,
                                        sentence: "the node it comes from, #\(wire.fromNodeID), does not exist"))
                continue
            }
            guard let toNode = context.nodesByID[wire.toNodeID] else {
                findings.append(Finding(kind: .danglingWire, subject: subject,
                                        sentence: "the node it goes to, #\(wire.toNodeID), does not exist"))
                continue
            }

            let fromPort = FatalErrors.attempt {
                try context.database.outputPort.select(nodeID: wire.fromNodeID, nameSymbolID: wire.fromSymbolID)
            } ?? nil
            if fromPort == nil {
                findings.append(Finding(kind: .danglingWire, subject: subject,
                                        sentence: "\(Self.subject(fromNode)) has no output port "
                                                + "'\(name(ofSymbol: wire.fromSymbolID, in: context))'"))
            }

            // Only when the type is linked: a node whose type is gone declares no ports at
            // all, and reporting every wire into it would bury the one finding that says so.
            let toPortName = name(ofSymbol: wire.toSymbolID, in: context)
            if let descriptor = descriptor(ofKind: toNode.kind),
               !descriptor.inputPorts.contains(where: { $0.name == toPortName }) {
                findings.append(Finding(kind: .danglingWire, subject: subject,
                                        sentence: "\(Self.subject(toNode)) declares no input port '\(toPortName)'"))
            }
        }

        return findings
    }

    // MARK: - A graph spec that cannot be read back, or names a type the server does not link

    /// A node's `graphSpec` is its identity: it is what `findOrCreateMatchingNode` matches
    /// against, so a spec that cannot be read back is a node nothing will ever find again,
    /// and one naming an absent type is a node nothing can rebuild.
    private static func graphSpecs(_ context: Context) -> [Finding] {
        var findings: [Finding] = []

        for node in context.nodes {
            guard let graphSpec = node.graphSpec else {
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
    private static func productsWithNoProducer(_ context: Context) -> [Finding] {
        let wiredPorts = Set(context.wires.map { WiredPort(nodeID: $0.toNodeID, symbolID: $0.toSymbolID) })

        var findings: [Finding] = []

        for node in context.nodes {
            guard let nodeID = node.id, let descriptor = descriptor(ofKind: node.kind) else {
                continue
            }
            for portName in descriptor.requiredInputPorts {
                // Through the table rather than `asSymbolID()`, which would intern: a name
                // the table does not hold is a name no wire can be carrying either.
                let symbolID = FatalErrors.attempt { try context.database.symbol.selectID(name: portName) } ?? nil
                if let symbolID, wiredPorts.contains(WiredPort(nodeID: nodeID, symbolID: symbolID)) {
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

    // MARK: - A folder manifest naming a child that does not exist

    /// Every name a folder advertises is a node under it. The manifest is what the nodes
    /// downstream of a folder read, so a name in it that no child answers to is a build
    /// asking for a file that is not there.
    ///
    /// A folder marked dirty is passed over: its manifest is waiting to be rebuilt, which
    /// is the engine working as designed and not an invariant that does not hold. The
    /// rebuild is deliberately not triggered here — reading a port must not be what repairs
    /// it, in the one command that repairs nothing.
    private static func folderManifests(_ context: Context) -> [Finding] {
        let dirtyKeys = FatalErrors.attempt {
            try context.database.metadata.selectKeys(withPrefix: Folder.manifestDirtyKeyPrefix)
        } ?? []
        let dirtyIDs = Set(dirtyKeys.compactMap { ObjectID($0.dropFirst(Folder.manifestDirtyKeyPrefix.count)) })

        var childNames: [ObjectID: Set<String>] = [:]
        for node in context.nodes {
            guard let parentNodeID = node.parentNodeID, let name = node.name else {
                continue
            }
            childNames[parentNodeID, default: []].insert(name)
        }

        var findings: [Finding] = []

        for node in context.nodes where node.kind == Folder.kind {
            guard let nodeID = node.id, !dirtyIDs.contains(nodeID),
                  let manifest = readManifest(ofFolder: nodeID, in: context) else {
                continue
            }
            let names = childNames[nodeID] ?? []
            for entry in manifest.entries where !names.contains(entry.name) {
                findings.append(Finding(kind: .missingManifestChild, subject: subject(node),
                                        sentence: "its manifest names the child '\(entry.name)', "
                                                + "which does not exist"))
            }
        }

        return findings
    }

    /// The manifest a folder is publishing, or nil when it is not publishing one — a
    /// folder whose port holds a state rather than a value has nothing to disagree with.
    private static func readManifest(ofFolder nodeID: ObjectID, in context: Context) -> FolderManifest? {
        guard let symbolID = (FatalErrors.attempt {
                  try context.database.symbol.selectID(name: Folder.folderManifestOutputPort)
              } ?? nil),
              let port = (FatalErrors.attempt {
                  try context.database.outputPort.select(nodeID: nodeID, nameSymbolID: symbolID)
              } ?? nil),
              port.valueKind == .value,
              let json = try? port.dataObjectHash?.resolveAsString() else {
            return nil
        }
        return try? TypeRegistry.decodeAndCast(encodedJSON: json)
    }

    // MARK: - An error port with no message

    /// An error carrying nothing is the one failure a reader cannot act on: the report
    /// prints "an error with no message" and there is nowhere further to go. The node that
    /// wrote it is the bug, and this is what names it.
    private static func errorPortsWithoutMessages(_ context: Context) -> [Finding] {
        let errorPorts = FatalErrors.attempt { try context.database.outputPort.selectAllErrors() } ?? []

        // By case, not by text: a port carrying an input's failure has no message of its
        // own and is not supposed to have one.
        return errorPorts
            .filter { $0.valueKind == .error && message(of: $0).isEmpty }
            .map { port in
                Finding(kind: .errorWithoutMessage,
                        subject: subject(nodeID: port.nodeID, in: context),
                        sentence: "its port '\(name(ofSymbol: port.nameSymbolID, in: context))' is in error "
                                + "with no message, so nothing says what failed")
            }
    }

    // MARK: - A cache entry whose key is not the shape a key has

    /// A cache key is the hex of a hash and has no other shape. One that is not says the
    /// row was written by something other than `Cache.buildCacheKeyFromAllInputs`, and a
    /// key that cannot be recomputed is an entry nothing will ever hit again.
    private static func cacheKeys(_ context: Context) -> [Finding] {
        let hashes = FatalErrors.attempt { try context.database.cacheEntry.selectAllHashes() } ?? []

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
