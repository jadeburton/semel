//
//  GraphSpecApplier.swift
//  semel
//
//  Live-graph operations for GraphSpecNode:
//    • Building a spec from the database (build)
//    • Searching the database for a matching node (find)
//    • Creating missing nodes and wires atomically (create)
//    • Recomputing Node.graphSpec for all nodes
//
//  Pure model, serialisation, and parsing live in GraphSpec.swift.
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

// MARK: - graphSpecProperties — extracting init-time properties from a live node

extension Node {
    /// Default: delegate to `WithProperties` if the type conforms, else no properties.
    /// Declared in the protocol so Swift dispatches dynamically via the witness table.
}

extension Node {
    func graphSpecProperties() -> [GraphSpecProperty] {
        thisNode.properties
            .sorted(by: { $0.key < $1.key })
            .map { GraphSpecProperty(key: $0.key, value: $0.value) }
    }
}

// MARK: - Build spec from the live graph

extension GraphSpecNode {

    /// Wire-endpoint form: includes the `.outputPort` suffix.
    /// Used when building spec strings or comparing wires.
    static func buildFromWire(_ wire: Wire, database: DatabaseLayer) throws -> GraphSpecNode {
        var visited = Set<ObjectID>()
        return try buildFromOrigin(database: database,
                                   fromNodeID: wire.fromNodeID,
                                   fromSymbolID: wire.fromSymbolID,
                                   includeOutputPort: true,
                                   visited: &visited)
    }

    /// Node-identity form: no `.outputPort` suffix.
    /// Used when computing `Node.graphSpec`.
    static func buildFromNode(database: DatabaseLayer, nodeID: ObjectID,
                              fromSymbolID: ObjectID? = nil) throws -> GraphSpecNode {

        var visited = Set<ObjectID>()
        return try buildFromOrigin(database: database,
                                   fromNodeID: nodeID,
                                   fromSymbolID: fromSymbolID,
                                   includeOutputPort: fromSymbolID != nil,
                                   visited: &visited)
    }

    static func buildFromOrigin(database: DatabaseLayer,
                                fromNodeID: ObjectID,
                                fromSymbolID: ObjectID?,
                                includeOutputPort: Bool,
                                visited: inout Set<ObjectID>) throws -> GraphSpecNode {

        let outputPortName: String? = (includeOutputPort && fromSymbolID != nil)
            ? fromSymbolID!.resolveSymbol() : nil

        let sourceNode   = try database.node.select(nodeID: fromNodeID)
        let node = try sourceNode.makeNode()
        let typeName     = String(describing: type(of: node))

        // Cycle guard — return a stub with no inputs to stop infinite recursion.
        guard !visited.contains(fromNodeID) else {
            return GraphSpecNode(typeName: typeName, outputPort: outputPortName)
        }
        visited.insert(fromNodeID)

        let properties = node.graphSpecProperties()

        // Only static ports are included.  Dynamic ports (e.g. includeFileLists)
        // are managed by the engine after the schema is laid down; including them
        // would make graphSpec change on every cycle, breaking topology matching.
        let staticInputPorts = node.descriptor.staticInputPorts

        var inputs: [GraphSpecInputPort] = []

        for portName in staticInputPorts {
            let portSymbolID  = portName.asSymbolID()

            let incomingWires = try database.wire.select(goingToNodeID: fromNodeID,
                                                         toSymbolID: portSymbolID)

            guard !incomingWires.isEmpty else {
                continue
            }

            var wires: [GraphSpecWire] = []
            for wire in incomingWires {
                var branchVisited = visited          // each branch gets its own copy
                let childNode = try buildFromOrigin(database: database,
                                                    fromNodeID: wire.fromNodeID,
                                                    fromSymbolID: wire.fromSymbolID,
                                                    includeOutputPort: true,
                                                    visited: &branchVisited)
                let wireName  = wire.name.resolveSymbol()
                wires.append(GraphSpecWire(name: wireName, node: childNode))
            }
            inputs.append(GraphSpecInputPort(portName: portName, wires: wires))
        }

        return GraphSpecNode(typeName: typeName, properties: properties, inputs: inputs, outputPort: outputPortName)
    }
}

// MARK: - Search for a matching node in the live graph

extension GraphSpecNode {

    var database: DatabaseLayer {
        DatabaseLayer.shared
    }

    private func findMatchingNodeUsingGraphSpec() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        let thisGraphSpec = asString(omitOutputPort: true)

        guard let nodeRecord = try database.node.select(graphSpec: thisGraphSpec).first else {
            return nil
        }

        return (fromNodeID: (try nodeRecord.requireID()), fromSymbolID: outputPort?.asSymbolID())
    }

    /// A node is found by its rendered spec: `asString` is canonical, so an equal demand
    /// renders to an equal string and the lookup is an indexed one on `Node.graphSpec`.
    func findMatchingNode() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        try findMatchingNodeUsingGraphSpec()
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
    /// This eliminates the `UNIQUE constraint failed: Node.graphSpec` crash that
    /// occurred when both tasks ran the find outside a transaction, both saw nil,
    /// and then both tried to insert the same graphSpec.
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
                                          graphSpec: asString(omitOutputPort: true))

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
