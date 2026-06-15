//
//  GraphShapeApplier.swift
//  build_system
//
//  Live-graph operations for GraphShapeNode:
//    • Building a shape from the database (build)
//    • Searching the database for a matching node (find)
//    • Creating missing nodes and wires (create)
//    • Recomputing Node.searchKey for all nodes
//
//  Pure model, serialisation, and parsing live in GraphShape.swift.
//

import Foundation

// MARK: - graphShapeArgs — extracting init-time arguments from a live node

extension InputlessNodeFunction {
    /// Default: no init-time args.  Override in concrete types (e.g. `StaticFile`).
    func graphShapeArgs(node: Node) -> [GraphShapeArg] {
        (self as? WithProperties)?.properties.map { GraphShapeArg(key: $0.key, value: $0.value) } ?? []
    }
}

extension StaticFile {
    func graphShapeArgs(node: Node) -> [GraphShapeArg] {
        let path = (try? node.buildFullPathName()) ?? ""
        return [GraphShapeArg(key: "path", value: path)]
    }
}

// MARK: - Build shape from the live graph

extension GraphShapeNode {

    /// Wire-endpoint form: includes the `.outputPort` suffix.
    /// Used when building expectation strings or comparing wires.
    static func buildFromWire(_ wire: Wire) throws -> GraphShapeNode {
        var visited = Set<ObjectID>()
        return try buildFromOrigin(fromNodeID:       wire.fromNodeID,
                                   fromSymbolID:     wire.fromSymbolID,
                                   includeOutputPort: true,
                                   visited:          &visited)
    }

    /// Node-identity form: no `.outputPort` suffix.
    /// Used when computing `Node.searchKey`.
    static func buildFromNode(nodeID: ObjectID) throws -> GraphShapeNode {
        var visited = Set<ObjectID>()
        return try buildFromOrigin(fromNodeID:       nodeID,
                                   fromSymbolID:     nil,
                                   includeOutputPort: false,
                                   visited:          &visited)
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

        // Cycle guard — return a stub with no inputs
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

            var children: [GraphShapeNode] = []
            for wire in incomingWires {
                var branchVisited = visited          // each branch gets its own copy
                children.append(try buildFromOrigin(fromNodeID:       wire.fromNodeID,
                                                    fromSymbolID:     wire.fromSymbolID,
                                                    includeOutputPort: true,
                                                    visited:          &branchVisited))
            }
            inputs.append(GraphShapeInputPort(portName: portName, value: children))
        }

        return GraphShapeNode(typeName: typeName, args: args, inputs: inputs, outputPort: outputPortName)
    }
}

// MARK: - Search for a matching node in the live graph

extension GraphShapeNode {

    func findMatchingNode() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        let allNodes   = try DatabaseLayer.shared.selectAllNodes()
        let candidates = allNodes.filter { node in
            guard let fn = try? node.nodeFunction() else { return false }
            return String(describing: type(of: fn)) == typeName
        }
        for candidate in candidates {
            guard let nodeID = candidate.id else { continue }
            if try matchesNode(nodeID: nodeID) {
                return (fromNodeID: nodeID, fromSymbolID: outputPort?.asSymbolID())
            }
        }
        return nil
    }

    private func matchesNode(nodeID: ObjectID) throws -> Bool {
        let node         = try nodeID.loadNode()
        let nodeFunction = try node.nodeFunction()
        guard String(describing: type(of: nodeFunction)) == typeName else { return false }

        let actualArgs = nodeFunction.graphShapeArgs(node: node)
        guard actualArgs == args else { return false }

        for expectedPort in inputs {
            let portSymbolID = expectedPort.portName.asSymbolID()
            let actualWires  = try DatabaseLayer.shared.selectWires(goingToNodeID: nodeID,
                                                                    toSymbolID:    portSymbolID)
            guard actualWires.count == expectedPort.value.count else { return false }
            for (wire, expectedChild) in zip(actualWires, expectedPort.value) {
                var visited: Set<ObjectID> = []
                let actualChild = try GraphShapeNode.buildFromOrigin(
                    fromNodeID:       wire.fromNodeID,
                    fromSymbolID:     wire.fromSymbolID,
                    includeOutputPort: true,
                    visited:          &visited)
                guard actualChild == expectedChild else { return false }
            }
        }
        return true
    }
}

// MARK: - Find or create a matching node in the live graph

extension GraphShapeNode {

    /// Returns the `(fromNodeID, fromSymbolID)` of the first matching node,
    /// creating the node (and any missing upstream nodes and wires) if none is found.
    func findOrCreateMatchingNode() throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        if let existing = try findMatchingNode() { return existing }
        guard let newNodeID = try createNode() else { return nil }
        return (fromNodeID: newNodeID, fromSymbolID: outputPort?.asSymbolID())
    }

    private func createNode() throws -> ObjectID? {
        let kind: UInt
        do {
            kind = try PolyFactory.kind(forTypeName: typeName)
        } catch {
            print("GraphShapeNode.createNode: unknown type '\(typeName)' — \(error)")
            return nil
        }

        if kind == StaticFile.kind {
            guard let pathArg = args.first(where: { $0.key == "path" }) else {
                print("GraphShapeNode.createNode: StaticFile missing 'path' arg")
                return nil
            }
            let inputFS = try Node.inputFileSystem
            guard let node = try inputFS.childNode(path: pathArg.value,
                                                    kind: StaticFile.kind,
                                                    createIfNotExist: true,
                                                    properties: nil) else { return nil }
            return node.id
        }

        let rootNode   = try Node.rootNode
        let properties = Dictionary(uniqueKeysWithValues: args.map { ($0.key, $0.value) })
        var newNode    = try Node.createNode(parentNodeID: rootNode.id!,
                                             kind:        kind,
                                             name:        typeName,
                                             properties:  properties.isEmpty ? nil : properties)
        let newNodeID  = newNode.id!

        for inputPortSpec in inputs {
            let toSymbolID = inputPortSpec.portName.asSymbolID()
            for (index, childShape) in inputPortSpec.value.enumerated() {
                if let (fromNodeID, fromSymbolID) = try childShape.findOrCreateMatchingNode() {
                    guard let fromSymbolID else { continue }
                    // Name the wire after the source node, matching the project convention.
                    let sourceNode = try fromNodeID.loadNode()
                    let wireName   = (sourceNode.name ?? "\(inputPortSpec.portName)[\(index)]").asSymbolID()
                    try Wire.connectWire(fromNodeID:   fromNodeID,
                                         fromSymbolID: fromSymbolID,
                                         toNodeID:     newNodeID,
                                         toSymbolID:   toSymbolID,
                                         name:         wireName)
                }
            }
        }

        try newNode.setScheduledAndSave(true)
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
                newSearchKey = try GraphShapeNode.buildFromNode(nodeID: nodeID).asString()
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
