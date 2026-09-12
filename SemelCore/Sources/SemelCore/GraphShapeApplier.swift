//
//  GraphShapeApplier.swift
//  semel
//
//  Live-graph operations for GraphShapeNode:
//    • Building a shape from the database (build)
//    • Searching the database for a matching node (find)
//    • Creating missing nodes and wires atomically (create)
//    • Recomputing Node.searchKey for all nodes
//
//  Pure model, serialisation, and parsing live in GraphShape.swift.
//

import Foundation
import SemelNodeKit

// MARK: - Errors

enum GraphShapeApplierError: Error {
    /// The type name in the shape string is not registered in TypeRegistry.
    case unknownTypeName(String)
    /// A required static input port has no wire connected after node creation.
    case requiredPortUnwired(typeName: String, portName: String)
    /// `findOrCreateMatchingNode` was called on a shape that could not be resolved.
    case couldNotResolveShape(typeName: String)
    /// A child shape returned a nil fromSymbolID when one was required for wiring.
    case missingOutputPortInChildShape(typeName: String)

    case emtpyStringWireName
}

// MARK: - graphShapeProperties — extracting init-time properties from a live node

extension Node {
    /// Default: delegate to `WithProperties` if the type conforms, else no properties.
    /// Declared in the protocol so Swift dispatches dynamically via the witness table.
}

extension Node {
    func graphShapeProperties() -> [GraphShapeProperty] {
        thisNode.properties
            .sorted(by: { $0.key < $1.key })
            .map { GraphShapeProperty(key: $0.key, value: $0.value) }
    }
}

// MARK: - Build shape from the live graph

extension GraphShapeNode {

    /// Wire-endpoint form: includes the `.outputPort` suffix.
    /// Used when building expectation strings or comparing wires.
    static func buildFromWire(_ wire: Wire, database: DatabaseLayer) throws -> GraphShapeNode {
        var visited = Set<ObjectID>()
        return try buildFromOrigin(database: database,
                                   fromNodeID: wire.fromNodeID,
                                   fromSymbolID: wire.fromSymbolID,
                                   includeOutputPort: true,
                                   visited: &visited)
    }

    /// Node-identity form: no `.outputPort` suffix.
    /// Used when computing `Node.searchKey`.
    static func buildFromNode(database: DatabaseLayer, nodeID: ObjectID,
                              fromSymbolID: ObjectID? = nil) throws -> GraphShapeNode {

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
                                visited: inout Set<ObjectID>) throws -> GraphShapeNode {

        let outputPortName: String? = (includeOutputPort && fromSymbolID != nil)
            ? fromSymbolID!.resolveSymbol() : nil

        let sourceNode   = try database.node.select(nodeID: fromNodeID)
        let node = try sourceNode.makeNode()
        let typeName     = String(describing: type(of: node))

        // Cycle guard — return a stub with no inputs to stop infinite recursion.
        guard !visited.contains(fromNodeID) else {
            return GraphShapeNode(typeName: typeName, outputPort: outputPortName)
        }
        visited.insert(fromNodeID)

        let properties = node.graphShapeProperties()

        // Only static ports are included.  Dynamic ports (e.g. includeFileLists)
        // are managed by the engine after the schema is laid down; including them
        // would make searchKey change on every cycle, breaking topology matching.
        let staticInputPorts = node.descriptor.staticInputPorts

        var inputs: [GraphShapeInputPort] = []

        for portName in staticInputPorts {
            let portSymbolID  = portName.asSymbolID()

            let incomingWires = try database.wire.select(goingToNodeID: fromNodeID,
                                                         toSymbolID: portSymbolID)

            guard !incomingWires.isEmpty else {
                continue
            }

            var wires: [GraphShapeWire] = []
            for wire in incomingWires {
                var branchVisited = visited          // each branch gets its own copy
                let childNode = try buildFromOrigin(database: database,
                                                    fromNodeID: wire.fromNodeID,
                                                    fromSymbolID: wire.fromSymbolID,
                                                    includeOutputPort: true,
                                                    visited: &branchVisited)
                let wireName  = wire.name.resolveSymbol()
                wires.append(GraphShapeWire(name: wireName, node: childNode))
            }
            inputs.append(GraphShapeInputPort(portName: portName, wires: wires))
        }

        return GraphShapeNode(typeName: typeName, properties: properties, inputs: inputs, outputPort: outputPortName)
    }
}

// MARK: - Search for a matching node in the live graph

extension GraphShapeNode {

    var database: DatabaseLayer {
        DatabaseLayer.shared
    }

    /// Returns `(fromNodeID, fromSymbolID)` of the first live node whose topology
    /// matches `self`, or `nil` if no match exists.
    private func findMatchingNodeBruteForce() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        for nodeRecord in try database.node.selectAll() {
            let graphShape = try GraphShapeNode.buildFromNode(database: database,
                                                              nodeID: (try nodeRecord.requireID()),
                                                              fromSymbolID: outputPort?.asSymbolID()).asString(omitOutputPort: true)

            if graphShape == asString(omitOutputPort: true) {
                return (fromNodeID: (try nodeRecord.requireID()), fromSymbolID: outputPort?.asSymbolID())
            }
        }

        return nil
    }

    private func findMatchingNodeUsingSearchKey() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        let thisGraphShape = asString(omitOutputPort: true)

        guard let nodeRecord = try database.node.select(searchKey: thisGraphShape).first else {
            return nil
        }

        return (fromNodeID: (try nodeRecord.requireID()), fromSymbolID: outputPort?.asSymbolID())
    }

    func findMatchingNode() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        try findMatchingNodeUsingSearchKey()
    }

    private func matchesNode(nodeID: ObjectID) throws -> Bool {
        let nodeRecord = try database.node.select(nodeID: nodeID)
        let node = try nodeRecord.makeNode()

        guard String(describing: type(of: node)) == typeName else {
            return false
        }

        let actualProperties = node.graphShapeProperties()

        guard Set(actualProperties) == Set(properties) else {
            return false
        }

        for expectedPort in inputs {
            let portSymbolID = expectedPort.portName.asSymbolID()
            let actualWires  = try database.wire.select(goingToNodeID: nodeID,
                                                                    toSymbolID:    portSymbolID)

            guard actualWires.count == expectedPort.wires.count else {
                return false
            }

            for (actualWire, expectedWire) in zip(actualWires, expectedPort.wires) {

                // Compare wire name (unless the expected name is empty — old format).
                if !expectedWire.name.isEmpty {
                    guard actualWire.name.resolveSymbol() == expectedWire.name else {
                        return false
                    }
                }

                var visited: Set<ObjectID> = []

                let actualChild = try GraphShapeNode.buildFromOrigin(database: database,
                                                                     fromNodeID: actualWire.fromNodeID,
                                                                     fromSymbolID: actualWire.fromSymbolID,
                                                                     includeOutputPort: true,
                                                                     visited: &visited)

                guard actualChild == expectedWire.node else {
                    return false
                }
            }
        }
        return true
    }
}

// MARK: - Find or create a matching node in the live graph

extension GraphShapeNode {

    /// Returns `(fromNodeID, fromSymbolID)` of the matching node, creating it
    /// (and all missing upstream nodes and wires) if none exists.
    ///
    /// The find and create are wrapped in a **single** `withTransaction` so there
    /// is no TOCTOU gap between them.  When two concurrent tasks race to create the
    /// same node:
    ///   • Task A's transaction: find → nil  → insert → commit
    ///   • Task B's transaction: find → hit! → return Task A's node (no insert)
    ///
    /// This eliminates the `UNIQUE constraint failed: Node.searchKey` crash that
    /// occurred when both tasks ran the find outside a transaction, both saw nil,
    /// and then both tried to insert the same searchKey.
    ///
    /// Throws `GraphShapeApplierError` for all failure cases; never returns nil.
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
           let nodeRecord = try? database.node.select(nodeID: existing.fromNodeID) {
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
            throw GraphShapeApplierError.unknownTypeName(typeName)
        }

        // ── All other node types ───────────────────────────────────────────────
        let nodeProperties = properties.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: properties.map { ($0.key, $0.value) })

//        let startTime = Date.now

        let newNode = try NodeRecord.createNode(database: database,
                                          kind: kind,
                                          properties: nodeProperties,
                                          searchKey: asString(omitOutputPort: true))

//        print("createNode time elapsed: \(Date.now.timeIntervalSince(startTime))")

        // Wire each input port from the shape using the explicit wire name.
        for inputPortSpec in inputs {
            let toSymbolID = inputPortSpec.portName.asSymbolID()

            for wireSpec in inputPortSpec.wires {
                let createdNode = try newNode.makeNode()
                if !createdNode.descriptor.staticInputPorts.contains(inputPortSpec.portName) {
                    throw NodeError.other(message: "The formula refers to a port, '\(inputPortSpec.portName)', that does not exist in the implementation. Node: \(createdNode)")
                }

                let (fromNode, fromSymbolID) = try wireSpec.node.findOrCreateMatchingNode()

                guard let fromSymbolID else {
                    throw GraphShapeApplierError.missingOutputPortInChildShape(typeName: wireSpec.node.typeName)
                }

                if wireSpec.name.isEmpty {
                    throw GraphShapeApplierError.emtpyStringWireName
                }

                try Wire.connectWire(database: database,
                                     fromNodeID: (try fromNode.requireID()),
                                     fromSymbolID: fromSymbolID,
                                     toNodeID: (try newNode.requireID()),
                                     toSymbolID: toSymbolID,
                                     name: wireSpec.name.asSymbolID())
            }
        }

        // ── Validate: every required port declared in the shape must be wired ─
        let node  = try newNode.makeNode()
        let descriptor    = node.descriptor
        let optionalPorts = Set(descriptor.optionalStaticInputPorts)

        for portSpec in inputs where !optionalPorts.contains(portSpec.portName) {
            let portSymbolID   = portSpec.portName.asSymbolID()
            let connectedWires = try database.wire.select(goingToNodeID: (try newNode.requireID()), toSymbolID: portSymbolID)
            if connectedWires.isEmpty {
                // Throwing here causes withTransaction to roll back everything.
                throw GraphShapeApplierError.requiredPortUnwired(typeName: typeName,
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
