//
//  NodeSupport.swift
//  build_system
//
//  Created by Jade Burton on 14.06.26.
//

// MARK: - String helpers

extension String {
    /// Returns the string with the given suffix removed, or the original string
    /// unchanged if it does not end with that suffix.
    func removingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

extension Node {
    var database: DatabaseLayer {
        DatabaseLayer.shared
    }

    /// Returns the full logical path of this node from the root, e.g. `inputFileSystem/src/hello.c`.
    /// Returns `.empty` when the node is the specified `baseNodeID` (so callers can do relative paths).
    func buildFullPathName(baseNodeID: ObjectID?) throws -> Path {

        if let baseNodeID, id == baseNodeID {
            return .empty
        }

        func parentPath() throws -> Path {

            guard let parentNodeID else {
                return .empty
            }

            return try database.node.select(nodeID: parentNodeID).buildFullPathName(baseNodeID: baseNodeID)
        }

        guard let name, !name.isEmpty else {
            throw NodeError.other(message: "Node \(id!) in \(try parentPath()) has no name or it is empty; cannot build full path")
        }

        let parent = try parentPath()

        return parent.isEmpty ? Path(name) : parent / name
    }

    func nodeFunctionCast<N: InputlessNodeFunction>() throws -> N {
        try nodeFunction() as! N
    }

    func nodeFunction() throws -> InputlessNodeFunction {
        try (PolyFactory.type(kind: kind) as! InputlessNodeFunction.Type).init(thisNode: self)
    }

    var allChildren: [Node] {
        get throws {
            try DatabaseLayer.shared.node.select(parentNodeID: id!)
        }
    }

    static func createNode(database: DatabaseLayer, kind: UInt, properties: [String: String], searchKey: String?) throws -> Node {

        var node = Node(parentNodeID: nil,
                        kind: kind,
                        name: nil,
                        properties: properties,
                        scheduled: false,
                        searchKey: searchKey)

        node.id = try database.node.insert(node)

        let nodeFunction = try node.nodeFunction()

        node.name = nodeFunction.thisNode.name
        node.parentNodeID = nodeFunction.thisNode.parentNodeID

        assert(node.parentNodeID != node.id!)

        try node.writePendingToAllOutputsOfNode()

        let output = try nodeFunction.didCreate() ?? nodeFunction.buildErrorOutput(withError: NodeError.initializing)

        try nodeFunction.writeToOutputs(output: output)

        if nodeFunction is NodeFunction {
            try node.setScheduled(true)
        }

        if searchKey == nil {
            do {
                node.searchKey = try GraphShapeNode.buildFromNode(database: database, nodeID: node.id!).asString(omitOutputPort: true)
            } catch {
                print("WARNING: failed to patch-in searchKey (\(error)), are we attempting to create a duplicate Node? searchKey = \(node.searchKey ?? "(null)")")
                throw error
            }
        }

        try database.node.update(node)

        assert(node.searchKey != nil)

        try nodeFunction.notifyParentThisChildAdded()

        return node
    }

    /// Walk (creating as needed) the given path of folder nodes beneath `self`.
    /// Returns the deepest folder node.
    @discardableResult
    func ensureEntirePathExistsAsFolders(_ path: Path, pinned: Bool) throws -> Node {
        guard kind == Folder.kind else {
            throw NodeError.other(message: "Cannot ensure path exists on a non-folder node")
        }

        var currentFolder = self
        var pathSoFar = try buildFullPathName(baseNodeID: nil)

        for name in path.segments {
            pathSoFar = pathSoFar.isEmpty ? Path(name) : pathSoFar / name

            let existingChildren = try database.node.select(named: name, parentNodeID: currentFolder.id!)

            if existingChildren.count > 1 {
                // Can happen when folder and file have same name
                throw NodeError.other(message: "Multiple children with the same name '\(name)' under folder '\(currentFolder.name ?? "<no name>")'")
            }

            if let existingChild = existingChildren.first {
                if existingChild.kind != Folder.kind {
                    break
                }
                currentFolder = existingChild
            } else {
                assert(!pathSoFar.string.hasSuffix("/"))
                assert(!pathSoFar.string.hasPrefix("/"))

                let graphShape = try GraphShapeNode.parse("Folder(path: '\(pathSoFar.string)')")
                let (fromNode, _) = try graphShape.findOrCreateMatchingNode()
                var newFolder = fromNode
                newFolder.parentNodeID = currentFolder.id!
                try database.node.update(newFolder)

                try newFolder.nodeFunction().notifyParentThisChildAdded()
                currentFolder = newFolder
            }

            if pinned {
                let currentFolderNodeFunction = try currentFolder.nodeFunction()
                if let folder = currentFolderNodeFunction as? Folder {
                    if try !folder.isPinned {
                        try folder.setPinned(true)

                        // BUG TODO: this is very slow.
                        try currentFolderNodeFunction.notifyParentThisChildAdded()
                    }
                }
            }
        }

        return currentFolder
    }

    /// Convenience overload accepting a String path.
    @discardableResult
    func ensureEntirePathExistsAsFolders(_ path: String, pinned: Bool) throws -> Node {
        try ensureEntirePathExistsAsFolders(Path(path), pinned: pinned)
    }

    /// Walk the node tree by path segments, returning the node at the given path or `nil` if not found.
    func childNode(path: Path) throws -> Node? {
        guard !path.isEmpty else { return self }
        var currentNode = self
        for name in path.segments {
            guard let child = try database.node.select(named: name, parentNodeID: currentNode.id!).first else {
                return nil
            }
            currentNode = child
        }
        return currentNode
    }

    /// Convenience overload accepting a String path.
    func childNode(path: String) throws -> Node? {
        try childNode(path: Path(path))
    }

    func setScheduled(_ scheduled: Bool) throws {
        let nodeFunction = try self.nodeFunction()

        guard nodeFunction is NodeFunction else {
            print("Attempted to schedule a \(self) / \(type(of: nodeFunction)) that cannot be scheduled because it does not accept inputs. Ignoring.")
            return
        }

        try database.node.updateScheduled(nodeID: id!, scheduled: scheduled)

        if scheduled {
            BuildEngine.shared?.signalWorkAvailable()
        }
    }
}

// MARK: - Port management

extension Node {
    func hasOneOrMoreErrorOrPendingOutputs() throws -> Bool {
        try database.outputPort.selectAll(nodeID: id!).contains { $0.valueKind != .value }
    }

    func readFromOutputPort(_ outputPort: String) throws -> NodeValue {
        let outputSymbolID = outputPort.asSymbolID()

        guard let port = try database.outputPort.select(nodeID: id!, nameSymbolID: outputSymbolID) else {
            return .noValue(reason: .error(message: "No value ever existed"))
        }
        return try port.asNodeValue()
    }

    func readFromInputPort(_ inputPort: String) throws -> [String: NodeValue] {
        let inputSymbolID = inputPort.asSymbolID()

        let wiresOnThisInput = try database.wire.select(goingToNodeID: id!, toSymbolID: inputSymbolID)

        var result = [String: NodeValue]()

        for wire in wiresOnThisInput {
            let wireName = wire.name.resolveSymbol()
            if let port = try database.outputPort.select(nodeID: wire.fromNodeID, nameSymbolID: wire.fromSymbolID) {
                assert(result[wireName] == nil)
                try result[wireName] = port.asNodeValue()
            }
        }

        return result
    }

    func writePendingToAllOutputsOfNode() throws {
        for outputPort in try nodeFunction().descriptor.outputPorts {
            try writeToOutputPort(outputPort, value: .noValue(reason: .pending))
        }
    }

    @discardableResult func writeToOutputPort(_ outputPort: String, value: NodeValue) throws -> Bool {
        try writeToOutputPort(port: try value.mapPort(nodeID: id!, outputSymbolID: outputPort.asSymbolID()))
    }

    @discardableResult func writeToOutputPort(port: OutputPort) throws -> Bool {

        if let existing = try database.outputPort.select(nodeID: id!, nameSymbolID: port.nameSymbolID) {
            if existing == port { return false }
        }

        try database.outputPort.insertOrUpdate(port)

        for wire in try database.wire.select(comingFromNodeID: id!, fromSymbolID: port.nameSymbolID) {
            let toNode = try database.node.select(nodeID: wire.toNodeID)

            try toNode.writePendingToAllOutputsOfNode()

            if port.valueKind != .pending {
                try toNode.setScheduled(true)
            }
        }
        return true
    }
}
