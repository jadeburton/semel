//
//  NodeSupport.swift
//  build_system
//
//  Created by Jade Burton on 14.06.26.
//

// MARK: - String helpers

import SemelNodeKit

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

    /// Returns the full logical path of this node from the root, e.g. `input:/src/hello.c`.
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
            throw NodeError.other(message: "Node \(try requireID()) in \(try parentPath()) has no name or it is empty; cannot build full path")
        }

        let parent = try parentPath()

        return parent.isEmpty ? Path(name) : parent / name
    }

    func nodeFunctionCast<N: NodeFunction>() throws -> N {
        try nodeFunction() as! N
    }

    func nodeFunction() throws -> any NodeFunction {
        try (PolyFactory.type(kind: kind) as! NodeFunction.Type).init(thisNode: self)
    }

    /// Returns the node function as `Any` so app-layer callers can pattern-match
    /// against concrete public types (e.g. `as? UserDeletable`, `as? FileType`).
    public func nodeAsAny() throws -> Any {
        try nodeFunction()
    }

    var allChildren: [Node] {
        get throws {
            try DatabaseLayer.shared.node.select(parentNodeID: (try requireID()))
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

        let nodeID = try node.requireID()
        assert(node.parentNodeID != nodeID, "a node cannot be its own parent")

        // The row was inserted above before the node function could report its name, so
        // the uniqueness check can only happen here — and a rejection has to back that
        // row out, or a failed creation leaves an unreachable orphan behind.
        if let name = node.name, let parentNodeID = node.parentNodeID {
            let siblings = try database.node.select(named: name, parentNodeID: parentNodeID)
            if let existing = siblings.first(where: { $0.id != nodeID }) {
                _ = try? database.node.delete(nodeID: nodeID)
                throw NodeError.nameCollision(path: try Self.describePath(database: database,
                                                                          parentNodeID: parentNodeID,
                                                                          name: name),
                                              existingKind: existing.kind)
            }
        }

        try node.writePendingToAllOutputsOfNode()

        let output = try nodeFunction.didCreate() ?? nodeFunction.buildErrorOutput(withError: NodeError.initializing)

        try nodeFunction.writeToOutputs(output: output)

        if type(of: nodeFunction).descriptor.hasInputs {
            try node.setScheduled(true)
        }

        if searchKey == nil {
            do {
                node.searchKey = try GraphShapeNode.buildFromNode(database: database, nodeID: (try node.requireID())).asString(omitOutputPort: true)
            } catch {
                Debug.warn("failed to patch in searchKey (\(error)) — a duplicate node? searchKey = \(node.searchKey ?? "(null)")")
                throw error
            }
        }

        try database.node.update(node)

        assert(node.searchKey != nil)

        try nodeFunction.notifyParentThisChildAdded()

        return node
    }

    /// Best-effort full path of a would-be child, for error messages only. Falls back to
    /// the bare name if the parent cannot be resolved — an error report must never fail.
    private static func describePath(database: DatabaseLayer, parentNodeID: ObjectID, name: String) throws -> String {
        guard let parent = try? database.node.select(nodeID: parentNodeID),
              let parentPath = try? parent.buildFullPathName(baseNodeID: nil) else {
            return name
        }
        return (parentPath / name).string
    }

    /// Walk (creating as needed) the given path of folder nodes beneath `self`.
    /// Returns the deepest folder node.
    @discardableResult
    public func ensureEntirePathExistsAsFolders(_ path: Path, pinned: Bool) throws -> Node {
        guard kind == Folder.kind else {
            throw NodeError.other(message: "Cannot ensure path exists on a non-folder node")
        }

        var currentFolder = self
        var pathSoFar = try buildFullPathName(baseNodeID: nil)

        for name in path.segments {
            pathSoFar = pathSoFar.isEmpty ? Path(name) : pathSoFar / name

            let existingChildren = try database.node.select(named: name, parentNodeID: (try currentFolder.requireID()))

            if existingChildren.count > 1 {
                // Can happen when folder and file have same name
                throw NodeError.other(message: "Multiple children with the same name '\(name)' under folder '\(currentFolder.name ?? "<no name>")'")
            }

            if let existingChild = existingChildren.first {
                if existingChild.kind != Folder.kind {
                    // Previously a `break`, which silently returned the last good folder
                    // and left the caller believing a path had been created that had not.
                    throw NodeError.nameCollision(path: pathSoFar.string, existingKind: existingChild.kind)
                }
                currentFolder = existingChild
            } else {
                assert(!pathSoFar.string.hasSuffix("/"))
                assert(!pathSoFar.string.hasPrefix("/"))

                let graphShape = try GraphShapeNode.parse("Folder(path: '\(pathSoFar.string)')")
                let (fromNode, _) = try graphShape.findOrCreateMatchingNode()
                var newFolder = fromNode
                newFolder.parentNodeID = (try currentFolder.requireID())
                try database.node.update(newFolder)

                try newFolder.nodeFunction().notifyParentThisChildAdded()
                currentFolder = newFolder
            }

            if pinned {
                if let folder = try currentFolder.nodeFunction() as? Folder, try !folder.isPinned {
                    // setPinned notifies the parent itself, through onChildContentChanged,
                    // and that is the whole notification this needs. Folder answers both that
                    // and onChildAdded with refreshOutputs, so announcing the pin a second
                    // time rebuilds the parent's manifest for nothing — buildManifest runs in
                    // full even when the resulting JSON is identical and the write is skipped.
                    //
                    // Content is also the accurate event: the child exists and has been
                    // announced by the time we reach here, so its presence is not what
                    // changed.
                    try folder.setPinned(true)
                }
            }
        }

        return currentFolder
    }

    /// Convenience overload accepting a String path.
    @discardableResult
    public func ensureEntirePathExistsAsFolders(_ path: String, pinned: Bool) throws -> Node {
        try ensureEntirePathExistsAsFolders(Path(path), pinned: pinned)
    }

    /// Walk the node tree by path segments, returning the node at the given path or `nil` if not found.
    public func childNode(path: Path) throws -> Node? {
        guard !path.isEmpty else { return self }
        var currentNode = self
        for name in path.segments {
            guard let child = try database.node.select(named: name, parentNodeID: (try currentNode.requireID())).first else {
                return nil
            }
            currentNode = child
        }
        return currentNode
    }

    /// Convenience overload accepting a String path.
    public func childNode(path: String) throws -> Node? {
        try childNode(path: Path(path))
    }

    func setScheduled(_ scheduled: Bool) throws {
        let nodeFunction = try self.nodeFunction()

        guard type(of: nodeFunction).descriptor.hasInputs else {
            Debug.warn("ignoring a request to schedule \(self) / \(type(of: nodeFunction)), which declares no inputs")
            return
        }

        try database.node.updateScheduled(nodeID: (try requireID()), scheduled: scheduled)

        if scheduled {
            BuildEngine.shared?.signalWorkAvailable()
        }
    }
}

// MARK: - Port management

extension Node {
    func hasOneOrMoreErrorOrPendingOutputs() throws -> Bool {
        try database.outputPort.selectAll(nodeID: (try requireID())).contains { $0.valueKind != .value }
    }

    func readFromOutputPort(_ outputPort: String) throws -> NodeValue {
        let outputSymbolID = outputPort.asSymbolID()

        guard let port = try database.outputPort.select(nodeID: (try requireID()), nameSymbolID: outputSymbolID) else {
            return .noValue(reason: .error(messageDataObjectHash: try "No value ever existed".intern()))
        }
        return try port.asNodeValue()
    }

    func readFromInputPort(_ inputPort: String) throws -> [String: NodeValue] {
        let inputSymbolID = inputPort.asSymbolID()

        let wiresOnThisInput = try database.wire.select(goingToNodeID: (try requireID()), toSymbolID: inputSymbolID)

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
        try writeToOutputPort(port: try value.asOutputPort(nodeID: (try requireID()), outputSymbolID: outputPort.asSymbolID()))
    }

    @discardableResult func writeToOutputPort(port: OutputPort) throws -> Bool {

        if let existing = try database.outputPort.select(nodeID: (try requireID()), nameSymbolID: port.nameSymbolID) {
            if existing == port { return false }
        }

        try database.outputPort.insertOrUpdate(port)

        for wire in try database.wire.select(comingFromNodeID: (try requireID()), fromSymbolID: port.nameSymbolID) {
            let toNode = try database.node.select(nodeID: wire.toNodeID)

            try toNode.writePendingToAllOutputsOfNode()

            if port.valueKind != .pending {
                try toNode.setScheduled(true)
            }
        }
        return true
    }
}
