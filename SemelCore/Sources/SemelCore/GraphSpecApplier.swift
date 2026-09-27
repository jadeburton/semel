//
//  GraphSpecApplier.swift
//  semel
//
//  Live-graph operations for GraphSpecNode:
//    • Searching the database for the node a tree describes, by identity (find)
//    • Creating missing nodes and wires atomically (create)
//
//  The model, its rendering, its parser and its identity live in SemelNodeKit; the
//  identity a stored node recomputes from its own wires is `NodeRecord.recomputedIdentity`.
//

import Foundation
import SemelNodeKit

// MARK: - Errors

/// A spec that could not be turned into live nodes and wires. Sentences rather than case
/// names, because the engine interns a thrown error's text onto the failing node's ports.
enum GraphSpecApplierError: Error, CustomStringConvertible {
    /// The type name in the spec string is not registered in TypeRegistry.
    case unknownTypeName(String)
    /// A required static input port has no wire connected after node creation.
    case requiredPortUnwired(typeName: String, portName: String)
    /// `findOrCreateMatchingNode` was called on a spec that could not be resolved.
    case couldNotResolveShape(typeName: String)
    /// A child spec returned a nil fromSymbolID when one was required for wiring.
    case missingOutputPortInChildShape(typeName: String)

    case emtpyStringWireName

    var description: String {
        switch self {
        case .unknownTypeName(let typeName):
            return "no node type is registered under the name '\(typeName)'"
        case .requiredPortUnwired(let typeName, let portName):
            return "\(typeName)'s required input '\(portName)' has nothing connected to it"
        case .couldNotResolveShape(let typeName):
            return "the \(typeName) this node asks for could not be found or created"
        case .missingOutputPortInChildShape(let typeName):
            return "the \(typeName) feeding this node names no output port to take a value from"
        case .emtpyStringWireName:
            return "a wire was asked for under an empty name"
        }
    }
}

// MARK: - Search for a matching node in the live graph

extension GraphSpecNode {

    var database: DatabaseLayer {
        DatabaseLayer.shared
    }

    /// A node is found by its identity (B-115): the hash of this tree, children first, is
    /// the hash the engine stored when it created the node, so an equal demand hashes to an
    /// equal identity and the lookup is an indexed one on `Node.identity`.
    func findMatchingNode() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        guard let nodeRecord = try database.node.select(identity: try appliedIdentity()).first else {
            return nil
        }
        return (fromNodeID: (try nodeRecord.requireID()), fromSymbolID: outputPort?.asSymbolID())
    }

    /// The tree's identity, with a type this Semel does not link reported as the applier's
    /// own error: it is the same fact — nothing can be found or made for that name — and
    /// the applier is where a caller reads it.
    private func appliedIdentity() throws -> String {
        do {
            return try identity()
        } catch GraphSpecIdentityError.unknownTypeName(let typeName) {
            throw GraphSpecApplierError.unknownTypeName(typeName)
        }
    }
}

// MARK: - Find or create a matching node in the live graph

extension GraphSpecNode {

    /// Returns `(fromNodeID, fromSymbolID)` of the matching node, creating it
    /// (and all missing upstream nodes and wires) if none exists.
    ///
    /// The find and create are wrapped in a **single** `withTransaction` so there
    /// is no TOCTOU gap between them.  When two concurrent tasks race to create the
    /// same node:
    ///   • Task A's transaction: find → nil  → insert → commit
    ///   • Task B's transaction: find → hit! → return Task A's node (no insert)
    ///
    /// This eliminates the `UNIQUE constraint failed: Node.identity` crash that
    /// occurred when both tasks ran the find outside a transaction, both saw nil,
    /// and then both tried to insert the same identity.
    ///
    /// Throws `GraphSpecApplierError` for all failure cases; never returns nil.
    public func findOrCreateMatchingNode() throws -> (fromNode: NodeRecord, fromSymbolID: ObjectID?) {
        // Fast path: a node that already exists needs no transaction.
        //
        // `withTransaction` is `dbQueue.write`, so every call queued behind GRDB's single
        // writer -- including the overwhelmingly common one that finds an existing node and
        // writes nothing. That did not merely cost transaction overhead; it serialised
        // concurrent node resolution against every actual write in the process.
        //
        // Safe because this path never inserts, so it cannot be one of the two racing
        // writers below. The worst it can do is miss a node another task has not committed
        // yet, which falls through to the transaction, where the second find sees it.
        if let existing = try findMatchingNode(),
           let nodeRecord = try database.node.find(nodeID: existing.fromNodeID) {
            return (fromNode: nodeRecord, fromSymbolID: outputPort?.asSymbolID())
        }

        let newNode: NodeRecord = try database.withTransaction {
            // Found again inside, deliberately. Between the read above and here another
            // task may have committed this very node, and find-then-create has to stay in
            // one transaction regardless: two tasks that both see nil and both insert are
            // exactly the UNIQUE constraint crash described above.
            if let existing = try findMatchingNode() {
                return try database.node.select(nodeID: existing.fromNodeID)
            }
            return try createNode()
        }
        return (fromNode: newNode, fromSymbolID: outputPort?.asSymbolID())
    }

    // MARK: Private — node + wire creation (runs inside withTransaction)

    private func createNode() throws -> NodeRecord {
        let kind: UInt
        do {
            kind = try TypeRegistry.kind(forTypeName: typeName)
        } catch {
            throw GraphSpecApplierError.unknownTypeName(typeName)
        }

        // ── All other node types ───────────────────────────────────────────────
        let nodeProperties = properties.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: properties.map { ($0.key, $0.value) })

//        let startTime = Date.now

        let newNode = try NodeRecord.createNode(database: database,
                                          kind: kind,
                                          properties: nodeProperties,
                                          identity: try appliedIdentity())

//        print("createNode time elapsed: \(Date.now.timeIntervalSince(startTime))")

        // Wire each input port from the spec using the explicit wire name.
        for inputPortSpec in inputs {
            let toSymbolID = inputPortSpec.portName.asSymbolID()

            for wireSpec in inputPortSpec.wires {
                let createdNode = try newNode.makeNode()
                if !createdNode.descriptor.staticInputPorts.contains(inputPortSpec.portName) {
                    throw NodeError.other(message: "The formula refers to a port, '\(inputPortSpec.portName)', that does not exist in the implementation. Node: \(createdNode)")
                }

                let (fromNode, fromSymbolID) = try wireSpec.node.findOrCreateMatchingNode()

                guard let fromSymbolID else {
                    throw GraphSpecApplierError.missingOutputPortInChildShape(typeName: wireSpec.node.typeName)
                }

                if wireSpec.name.isEmpty {
                    throw GraphSpecApplierError.emtpyStringWireName
                }

                try Wire.connectWire(database: database,
                                     fromNodeID: (try fromNode.requireID()),
                                     fromSymbolID: fromSymbolID,
                                     toNodeID: (try newNode.requireID()),
                                     toSymbolID: toSymbolID,
                                     name: wireSpec.name.asSymbolID())
            }
        }

        // ── Validate: every required port declared in the spec must be wired ─
        let node  = try newNode.makeNode()
        let descriptor    = node.descriptor
        let optionalPorts = Set(descriptor.optionalStaticInputPorts)

        for portSpec in inputs where !optionalPorts.contains(portSpec.portName) {
            let portSymbolID   = portSpec.portName.asSymbolID()
            let connectedWires = try database.wire.select(goingToNodeID: (try newNode.requireID()), toSymbolID: portSymbolID)
            if connectedWires.isEmpty {
                // Throwing here causes withTransaction to roll back everything.
                throw GraphSpecApplierError.requiredPortUnwired(typeName: typeName,
                                                                 portName: portSpec.portName)
            }
        }

        // A source node — a Folder, a StaticFile — has nothing to be handed, so it is
        // never scheduled.
        if type(of: node).descriptor.hasInputs {
            try newNode.setScheduled(true)
        }

        return newNode
    }
}
