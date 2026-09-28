//
//  GraphSpecApplier.swift
//  semel
//
//  Live-graph operations for demanded specs (B-121): the rows of a `GraphSpecTable`
//  found in the graph by the identity each is filed under, or created from the row — its
//  sources found or created the same way, depth first — and wired. A tree reaches the
//  graph the same way, folded into a table first, so there is one applier and it never
//  hashes a tree.
//
//  The model, its rendering, its parser, its identity and its table live in SemelNodeKit;
//  the identity a stored node recomputes from its own wires is
//  `NodeRecord.recomputedIdentity`.
//

import Foundation
import SemelNodeKit

// MARK: - Errors

/// A spec that could not be turned into live nodes and wires. Sentences rather than case
/// names, because the engine interns a thrown error's text onto the failing node's ports.
enum GraphSpecApplierError: Error, CustomStringConvertible {
    /// The type name in the spec is not registered in TypeRegistry.
    case unknownTypeName(String)
    /// A required static input port has no wire connected after node creation.
    case requiredPortUnwired(typeName: String, portName: String)
    /// A row whose source names no output port to wire from.
    case missingOutputPortInChildShape(typeName: String)
    /// A row filed under an identity that its own kind, properties and wires do not give
    /// it: a damaged table, since a fold files each row under exactly that.
    case identityMismatch(typeName: String, filedUnder: String, computed: String)

    case emtpyStringWireName

    var description: String {
        switch self {
        case .unknownTypeName(let typeName):
            return "no node type is registered under the name '\(typeName)'"
        case .requiredPortUnwired(let typeName, let portName):
            return "\(typeName)'s required input '\(portName)' has nothing connected to it"
        case .missingOutputPortInChildShape(let typeName):
            return "the \(typeName) feeding this node names no output port to take a value from"
        case .identityMismatch(let typeName, let filedUnder, let computed):
            return "a spec table files a \(typeName) under \(NodeIdentity.shown(filedUnder))… but its row gives "
                 + "\(NodeIdentity.shown(computed))…; no node is made from it"
        case .emtpyStringWireName:
            return "a wire was asked for under an empty name"
        }
    }
}

// MARK: - Folding for the applier

extension GraphSpecTable {

    /// `init(trees:)`, with a type this Semel does not link reported as the applier's own
    /// error: it is the same fact — nothing can be found or made for that name — and the
    /// applier is where a caller reads it.
    static func applied(trees: [String: [String: GraphSpecNode]]) throws -> GraphSpecTable {
        try translatingUnknownType { try GraphSpecTable(trees: trees) }
    }

    /// `folding(tree:)`, with the same translation.
    static func applied(tree specNode: GraphSpecNode) throws -> (table: GraphSpecTable, root: Reference) {
        try translatingUnknownType { try GraphSpecTable.folding(tree: specNode) }
    }

    private static func translatingUnknownType<Result>(_ work: () throws -> Result) throws -> Result {
        do {
            return try work()
        } catch GraphSpecIdentityError.unknownTypeName(let typeName) {
            throw GraphSpecApplierError.unknownTypeName(typeName)
        }
    }
}

// MARK: - A tree

extension GraphSpecNode {

    /// Returns `(fromNode, fromSymbolID)` of the node this tree describes, creating it
    /// (and all missing upstream nodes and wires) if none exists.
    ///
    /// The tree is folded into a table — each node hashed once, children first — and the
    /// table applied, so a node reached by two paths is found or made once and no subtree
    /// is hashed twice.
    ///
    /// Throws `GraphSpecApplierError` for all failure cases; never returns nil.
    public func findOrCreateMatchingNode() throws -> (fromNode: NodeRecord, fromSymbolID: ObjectID?) {
        let (table, root) = try GraphSpecTable.applied(tree: self)
        var applier = GraphSpecTableApplier(table: table, database: DatabaseLayer.shared)
        return (fromNode: try applier.node(identity: root.identity), fromSymbolID: root.outputPort?.asSymbolID())
    }
}

// MARK: - A table

/// Finds or creates the nodes a table's rows describe, by the identity each row is filed
/// under (B-121).
///
/// A row's key is the identity the graph stores for its node (`Node.identity`), so finding
/// one is an indexed lookup of the key as it stands: nothing is hashed and no tree is
/// built. Creating one reads the row — its type, its properties, and per port its wires'
/// sources by identity, each found or created in turn, depth first — and hashes the row
/// once, one level, to check it against its key before anything is made: a stored table is
/// read as it stands, and a node filed under the wrong identity would be matched by the
/// wrong demand for as long as it lived.
///
/// One applier is one application — a node's demands, or one tree. What it has found or
/// made it remembers by identity, so a node reached by many rows is looked up once. The
/// memory is sound only while nothing it holds is rolled back, and every roll-back here is
/// a throw that ends the application with the applier discarded.
struct GraphSpecTableApplier {
    let table:    GraphSpecTable
    let database: DatabaseLayer
    private var resolved: [String: NodeRecord] = [:]

    init(table: GraphSpecTable, database: DatabaseLayer) {
        self.table    = table
        self.database = database
    }

    /// The node filed under `identity`, found or created.
    ///
    /// The type is looked up before the graph is, so a row naming a type this Semel does
    /// not link fails as a tree naming one does, whether or not something carries its
    /// identity.
    ///
    /// Found first outside any transaction, then again inside the one that creates. The
    /// first lookup is the common case — a node that exists needs no write — and
    /// `withTransaction` queues behind every other writer in the process. It never inserts,
    /// so it cannot be one of two racing creators; the lookup inside the transaction is
    /// what keeps find-then-create atomic, since two tasks that both saw nothing and both
    /// inserted would break `Node.identity`'s unique index.
    mutating func node(identity: String) throws -> NodeRecord {
        if let nodeRecord = resolved[identity] {
            return nodeRecord
        }
        let row = try table.row(identity: identity)
        guard let kind = try? TypeRegistry.kind(forTypeName: row.typeName) else {
            throw GraphSpecApplierError.unknownTypeName(row.typeName)
        }

        let nodeRecord: NodeRecord
        if let existing = try database.node.select(identity: identity).first {
            nodeRecord = existing
        } else {
            let database = self.database
            nodeRecord = try database.withTransaction {
                if let existing = try database.node.select(identity: identity).first {
                    return existing
                }
                return try createNode(identity: identity, kind: kind, row: row)
            }
        }
        resolved[identity] = nodeRecord
        return nodeRecord
    }

    // MARK: Creating a node from its row (runs inside withTransaction)

    /// The node first, then its wires, each from its source found or created: the order a
    /// node is created and wired in whichever way the demand arrived.
    private mutating func createNode(identity: String, kind: UInt, row: GraphSpecTable.Row) throws -> NodeRecord {
        let computed = try table.identity(of: row)
        guard computed == identity else {
            throw GraphSpecApplierError.identityMismatch(typeName: row.typeName, filedUnder: identity, computed: computed)
        }

        let nodeProperties = row.properties.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: row.properties.map { ($0.key, $0.value) })
        let newNode = try NodeRecord.createNode(database: database,
                                                kind: kind,
                                                properties: nodeProperties,
                                                identity: identity)
        let newNodeID   = try newNode.requireID()
        let createdNode = try newNode.makeNode()
        let descriptor  = createdNode.descriptor

        // Each port the row names, with its wires in the order the row lists them.
        for port in row.inputs {
            let toSymbolID = port.portName.asSymbolID()

            for wire in port.wires {
                if !descriptor.staticInputPorts.contains(port.portName) {
                    throw NodeError.other(message: "The formula refers to a port, '\(port.portName)', that does not exist in the implementation. Node: \(createdNode)")
                }

                let fromNode = try node(identity: wire.source.identity)

                guard let fromSymbolID = wire.source.outputPort?.asSymbolID() else {
                    throw GraphSpecApplierError.missingOutputPortInChildShape(typeName: (try table.row(identity: wire.source.identity)).typeName)
                }

                if wire.name.isEmpty {
                    throw GraphSpecApplierError.emtpyStringWireName
                }

                try Wire.connectWire(database: database,
                                     fromNodeID: (try fromNode.requireID()),
                                     fromSymbolID: fromSymbolID,
                                     toNodeID: newNodeID,
                                     toSymbolID: toSymbolID,
                                     name: wire.name.asSymbolID())
            }
        }

        // Every required port the row names must be wired.
        let optionalPorts = Set(descriptor.optionalStaticInputPorts)
        for port in row.inputs where !optionalPorts.contains(port.portName) {
            let connectedWires = try database.wire.select(goingToNodeID: newNodeID, toSymbolID: port.portName.asSymbolID())
            if connectedWires.isEmpty {
                // Throwing here causes withTransaction to roll back everything.
                throw GraphSpecApplierError.requiredPortUnwired(typeName: row.typeName, portName: port.portName)
            }
        }

        // A source node — a Folder, a StaticFile — has nothing to be handed, so it is
        // never scheduled.
        if type(of: createdNode).descriptor.hasInputs {
            try newNode.setScheduled(true)
        }

        return newNode
    }
}
