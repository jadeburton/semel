//
//  GraphShapeApplier.swift
//  build_system
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

// MARK: - Errors

enum GraphShapeApplierError: Error {
    /// The type name in the shape string is not registered in PolyFactory.
    case unknownTypeName(String)
    /// A required static input port has no wire connected after node creation.
    case requiredPortUnwired(typeName: String, portName: String)
    /// `findOrCreateMatchingNode` was called on a shape that could not be resolved.
    case couldNotResolveShape(typeName: String)
    /// A child shape returned a nil fromSymbolID when one was required for wiring.
    case missingOutputPortInChildShape(typeName: String)
}

// MARK: - graphShapeArgs — extracting init-time arguments from a live node

extension InputlessNodeFunction {
    /// Default: delegate to `WithProperties` if the type conforms, else no args.
    /// Declared in the protocol so Swift dispatches dynamically via the witness table.
    func graphShapeArgs(node: Node) -> [GraphShapeArg] {
        properties.map { GraphShapeArg(key: $0.key, value: $0.value) }
    }
}

// MARK: - Build shape from the live graph

extension GraphShapeNode {

    /// Wire-endpoint form: includes the `.outputPort` suffix.
    /// Used when building expectation strings or comparing wires.
    static func buildFromWire(_ wire: Wire) throws -> GraphShapeNode {
        var visited = Set<ObjectID>()
        return try buildFromOrigin(fromNodeID:        wire.fromNodeID,
                                   fromSymbolID:      wire.fromSymbolID,
                                   includeOutputPort: true,
                                   visited:           &visited)
    }

    /// Node-identity form: no `.outputPort` suffix.
    /// Used when computing `Node.searchKey`.
    static func buildFromNode(nodeID: ObjectID, fromSymbolID: ObjectID? = nil) throws -> GraphShapeNode {
        var visited = Set<ObjectID>()
        return try buildFromOrigin(fromNodeID:        nodeID,
                                   fromSymbolID:      fromSymbolID,
                                   includeOutputPort: fromSymbolID != nil,
                                   visited:           &visited)
    }

    static func buildFromOrigin(fromNodeID:        ObjectID,
                                fromSymbolID:      ObjectID?,
                                includeOutputPort: Bool,
                                visited:           inout Set<ObjectID>) throws -> GraphShapeNode {

        let outputPortName: String? = (includeOutputPort && fromSymbolID != nil)
            ? fromSymbolID!.resolveSymbol() : nil

        let sourceNode   = try fromNodeID.loadNode()
        let nodeFunction = try sourceNode.nodeFunction()
        let typeName     = String(describing: type(of: nodeFunction))

        // Cycle guard — return a stub with no inputs to stop infinite recursion.
        guard !visited.contains(fromNodeID) else {
            return GraphShapeNode(typeName: typeName, outputPort: outputPortName)
        }
        visited.insert(fromNodeID)

        let args = nodeFunction.graphShapeArgs(node: sourceNode)

        // Only static ports are included.  Dynamic ports (e.g. includeFileLists)
        // are managed by the engine after the schema is laid down; including them
        // would make searchKey change on every cycle, breaking topology matching.
        let staticInputPorts = nodeFunction.descriptor.staticInputPorts

        var inputs: [GraphShapeInputPort] = []
        for portName in staticInputPorts {
            let portSymbolID  = portName.asSymbolID()
            let incomingWires = try DatabaseLayer.shared.selectWires(goingToNodeID: fromNodeID,
                                                                     toSymbolID:    portSymbolID)
            guard !incomingWires.isEmpty else { continue }

            var wires: [GraphShapeWire] = []
            for wire in incomingWires {
                var branchVisited = visited          // each branch gets its own copy
                let childNode = try buildFromOrigin(fromNodeID:        wire.fromNodeID,
                                                    fromSymbolID:      wire.fromSymbolID,
                                                    includeOutputPort: true,
                                                    visited:           &branchVisited)
                let wireName  = wire.name.resolveSymbol()
                wires.append(GraphShapeWire(name: wireName, node: childNode))
            }
            inputs.append(GraphShapeInputPort(portName: portName, wires: wires))
        }

        return GraphShapeNode(typeName: typeName, args: args, inputs: inputs, outputPort: outputPortName)
    }
}

// MARK: - Search for a matching node in the live graph

extension GraphShapeNode {

    /// Returns `(fromNodeID, fromSymbolID)` of the first live node whose topology
    /// matches `self`, or `nil` if no match exists.
    func findMatchingNodeBruteForce() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        for node in try DatabaseLayer.shared.selectAllNodes() {
            let graphShape = try GraphShapeNode.buildFromNode(nodeID: node.id!, fromSymbolID: outputPort?.asSymbolID()).asString(omitOutputPort: true)

            if graphShape == asString(omitOutputPort: true) {
                return (fromNodeID: node.id!, fromSymbolID: outputPort?.asSymbolID())
            }
        }

        return nil
    }

    func findMatchingNodeUsingSearchKey() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        let thisGraphShape = asString(omitOutputPort: true)

        guard let node = try DatabaseLayer.shared.selectNodes(searchKey: thisGraphShape).first else {
            return nil
        }

        return (fromNodeID: node.id!, fromSymbolID: outputPort?.asSymbolID())
    }

    func findMatchingNode() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        try findMatchingNodeUsingSearchKey()
    }

    private func matchesNode(nodeID: ObjectID) throws -> Bool {
        let node         = try nodeID.loadNode()
        let nodeFunction = try node.nodeFunction()

        guard String(describing: type(of: nodeFunction)) == typeName else {
            return false
        }

        let actualArgs = nodeFunction.graphShapeArgs(node: node)

        guard actualArgs == args else { // TODO: is this order-insensitive?
            return false
        }

        for expectedPort in inputs {
            let portSymbolID = expectedPort.portName.asSymbolID()
            let actualWires  = try DatabaseLayer.shared.selectWires(goingToNodeID: nodeID,
                                                                    toSymbolID:    portSymbolID)

            guard actualWires.count == expectedPort.wires.count else {
                return false
            }

            for (actualWire, expectedWire) in zip(actualWires, expectedPort.wires) {
                // Compare wire name (unless the expected name is empty — old format).
                if !expectedWire.name.isEmpty {
                    guard actualWire.name.resolveSymbol() == expectedWire.name else { return false }
                }
                var visited: Set<ObjectID> = []
                let actualChild = try GraphShapeNode.buildFromOrigin(
                    fromNodeID:        actualWire.fromNodeID,
                    fromSymbolID:      actualWire.fromSymbolID,
                    includeOutputPort: true,
                    visited:           &visited)
                guard actualChild == expectedWire.node else { return false }
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
    /// All writes are wrapped in `DatabaseLayer.withTransaction` so any failure
    /// causes GRDB to roll back every write atomically — no partially-wired
    /// nodes are left behind.  Recursive calls re-enter `withTransaction`
    /// safely: inner calls detect the active transaction and participate in it.
    ///
    /// Throws `GraphShapeApplierError` for all failure cases; never returns nil.
    func findOrCreateMatchingNode() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?) {
        // Fast path: node already exists — no writes needed.
        if let existing = try findMatchingNode() {
            return existing
        }

        // Slow path: create inside a transaction so any error rolls back everything.
        let newNodeID = try DatabaseLayer.shared.withTransaction {
            try createNode()
        }

        return (fromNodeID: newNodeID, fromSymbolID: outputPort?.asSymbolID())
    }

    // MARK: Private — node + wire creation (runs inside withTransaction)

    private func createNode() throws -> ObjectID {
        let kind: UInt
        do {
            kind = try PolyFactory.kind(forTypeName: typeName)
        } catch {
            throw GraphShapeApplierError.unknownTypeName(typeName)
        }

        // ── All other node types ───────────────────────────────────────────────
        let properties = args.isEmpty ? [:]
                       : Dictionary(uniqueKeysWithValues: args.map { ($0.key, $0.value) })

        var newNode    = try Node.createNode(kind: kind, properties: properties, searchKey: asString(omitOutputPort: true))
        let newNodeID  = newNode.id!

        // Wire each input port from the shape using the explicit wire name.
        for inputPortSpec in inputs {
            let toSymbolID = inputPortSpec.portName.asSymbolID()
            for wireSpec in inputPortSpec.wires {
                let (fromNodeID, fromSymbolID) = try wireSpec.node.findOrCreateMatchingNode()
                guard let fromSymbolID else {
                    throw GraphShapeApplierError.missingOutputPortInChildShape(typeName: wireSpec.node.typeName)
                }
                // Use the explicit wire name from the shape when available;
                // fall back to the source node name for old unnamed (empty) entries.
                let sourceNode = try fromNodeID.loadNode()
                let wireName   = wireSpec.name.isEmpty
                    ? (sourceNode.name ?? "\(inputPortSpec.portName)[?]")
                    : wireSpec.name
                try Wire.connectWire(fromNodeID:   fromNodeID,
                                     fromSymbolID: fromSymbolID,
                                     toNodeID:     newNodeID,
                                     toSymbolID:   toSymbolID,
                                     name:         wireName.asSymbolID())
            }
        }

        // ── Validate: every required port declared in the shape must be wired ─
        let nodeFunction  = try newNode.nodeFunction()
        let descriptor    = nodeFunction.descriptor
        let optionalPorts = Set(descriptor.optionalStaticInputPorts)

        for portSpec in inputs where !optionalPorts.contains(portSpec.portName) {
            let portSymbolID   = portSpec.portName.asSymbolID()
            let connectedWires = try DatabaseLayer.shared.selectWires(goingToNodeID: newNodeID,
                                                                      toSymbolID:    portSymbolID)
            if connectedWires.isEmpty {
                // Throwing here causes withTransaction to roll back everything.
                throw GraphShapeApplierError.requiredPortUnwired(typeName: typeName,
                                                                 portName: portSpec.portName)
            }
        }

        if nodeFunction is NodeFunction { // don't schedule if it's not a NodeFunction (i.e. if it's just a Folder or similar)
            try newNode.setScheduledAndSave(true)
        }

        return newNodeID
    }
}

// MARK: - Recompute Node.searchKey for all nodes

extension DatabaseLayer {

    /// Recomputes `Node.searchKey` for every node and persists any changed values.
    /// Returns the number of rows actually updated.
    @discardableResult
    public func recomputeAllSearchKeys() throws -> Int {
        var updatedCount = 0
        for var node in try selectAllNodes() {
            guard let nodeID = node.id else { continue }
            let newSearchKey: String?
            do {
                newSearchKey = try GraphShapeNode.buildFromNode(nodeID: nodeID).asString(omitOutputPort: true)
            } catch {
                print("recomputeAllSearchKeys: skipping node #\(nodeID) (\(node.name ?? "?")) — \(error)")
                newSearchKey = nil
            }
            guard node.searchKey != newSearchKey else { continue }
            node.searchKey = newSearchKey
            try updateNode(node)
            updatedCount += 1
        }
        return updatedCount
    }
}
