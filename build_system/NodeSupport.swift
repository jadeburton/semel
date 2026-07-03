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

    /// The last path component of a slash-separated path string,
    /// e.g. "src/hello.c" → "hello.c", "hello.c" → "hello.c".
    var lastPathComponent: String {
        split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? self
    }

    /// Returns the path with the last component removed, or nil if there is no directory component.
    /// e.g. "src/foo/hello.c" → "src/foo", "hello.c" → nil, "src/hello.c" → "src"
    func deletingLastPathComponent() -> String? {
        let parts = split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    func deletingFirstPathComponent() -> String? {
        let parts = split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropFirst().joined(separator: "/")
    }

    /// Returns the path with the given component appended, joining with "/" as needed.
    /// e.g. "src".appendingPathComponent("hello.c") → "src/hello.c"
    /// e.g. "".appendingPathComponent("hello.c")    → "hello.c"
    func appendingPathComponent(_ component: String) -> String {
        assert(!component.isEmpty)
        if isEmpty { return component }
        if hasSuffix("/") { return self + component }
        return self + "/" + component
    }
}

extension DatabaseLayer {
    static var shared: DatabaseLayer {
        BuildEngine.shared.database
    }
}

extension Node {
    var database: DatabaseLayer {
        DatabaseLayer.shared
    }

    func buildFullPathName(baseNodeID: ObjectID?) throws -> String {
        if let baseNodeID {
            if id == baseNodeID {
                return ""
            }
        }

        func parentPath() throws -> String {
            guard let parentNodeID else {
                return ""
            }
            return try database.node.select(nodeID: parentNodeID).buildFullPathName(baseNodeID: baseNodeID) + "/"
        }

        assert(name == nil || !name!.isEmpty)
        return try parentPath() + (name ?? "<no name>")
    }

    func nodeFunctionCast<N: InputlessNodeFunction>() throws -> N {
        try nodeFunction() as! N
    }

    func nodeFunction() throws -> InputlessNodeFunction {
        try (PolyFactory.type(kind: kind) as! InputlessNodeFunction.Type).init(thisNode: self)
    }

    var allChildren: [Node] {
        get throws {
            try BuildEngine.shared.database.node.select(parentNodeID: id!)
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

        // Special case: we store some properties directly in the Node table itself, so we need to patch them in here
        node.name = nodeFunction.thisNode.name
        node.parentNodeID = nodeFunction.thisNode.parentNodeID

        assert(node.parentNodeID != node.id!)

        try node.writePendingToAllOutputsOfNode()

        let output = try nodeFunction.didCreate() ?? nodeFunction.buildErrorOutput(withError: NodeError.initializing)

        try nodeFunction.writeToOutputs(output: output)

        if nodeFunction is NodeFunction { // don't schedule if it's not a NodeFunction (i.e. if it's just a Folder or similar)
            try node.setScheduledAndSave(true)
        }

        // Patch in cached search key if one was not supplied
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

        // Locate parent node and notify its NodeFunction of this child's creation
        if let parentNodeID = node.parentNodeID {
            let parentNode = try database.node.select(nodeID: parentNodeID)
            if parentNode.kind == Folder.kind {
                try (parentNode.nodeFunctionCast() as Folder).notifyChildAdded(newChildNode: node)
            }
            // TODO: also when deleting Nodes or updating Nodes in any way
        }

        return node
    }

    @discardableResult
    func ensureEntirePathExistsAsFolders(_ path: String) throws -> Node {

        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var currentFolder = self

        guard kind == Folder.kind else {
            throw NodeError.other(message: "Cannot ensure path exists on a non-folder node")
        }

        var pathSoFar = try buildFullPathName(baseNodeID: nil)

        for name in components {

            if pathSoFar.isEmpty {
                pathSoFar += name
            } else {
                pathSoFar += "/" + name
            }

            let existingChildren = try database.node.select(named: name, parentNodeID: currentFolder.id!)

            if existingChildren.count > 1 {
                throw NodeError.other(message: "Multiple children with the same name '\(name)' under folder '\(currentFolder.name ?? "<no name>")'")
            }

            if let existingChild = existingChildren.first {
                currentFolder = existingChild
            } else {

                assert(!pathSoFar.hasSuffix("/"))
                assert(!pathSoFar.hasPrefix("/"))

                let graphShape = try GraphShapeNode.parse("Folder(path: '\(pathSoFar)')")
                let (fromNodeID, _) = try graphShape.findOrCreateMatchingNode()
                var newFolder = try database.node.select(nodeID: fromNodeID)
                newFolder.parentNodeID = currentFolder.id!
                try database.node.update(newFolder)

                try (currentFolder.nodeFunctionCast() as Folder).notifyChildAdded(newChildNode: newFolder)
                currentFolder = newFolder
            }
        }

        return currentFolder
    }

    func childNode(path: String) throws -> Node? {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var currentNode = self

        for (_, name) in components.enumerated() {
            guard let childNode = try database.node.select(named: name, parentNodeID: currentNode.id!).first else {
                return nil
            }

            currentNode = childNode
        }

        return currentNode
    }

    mutating func setScheduledAndSave(_ scheduled: Bool) throws {
        let nodeFunction = try self.nodeFunction()

        guard nodeFunction is NodeFunction else {
            // This NodeFunction has no "process" method and so cannot be scheduled.
            print("Attempted to schedule a \(self) / \(type(of: nodeFunction)) that cannot be scheduled because it does not accept inputs. Ignoring.")
            return
        }

        self.scheduled = scheduled

        // Use the targeted single-column update so we never accidentally
        // overwrite other columns (or another task's scheduling decision)
        // with a stale full-node snapshot.
        try database.node.updateScheduled(nodeID: id!, scheduled: scheduled)

        if scheduled {
            BuildEngine.shared.signalWorkAvailable()
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
                assert(result[wireName] == nil) // all wires must have unique names
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
            if existing == port {
               // print("No change to Port, ignoring (\(port.nameSymbolID.resolveSymbol()))")
                return false
            }
        }

        //let previousPort = try database.outputPort.select(nodeID: id!, nameSymbolID: port.nameSymbolID)
        //print("Output port '\(port.nameSymbolID.resolveSymbol())' of Node #\(id!) \(type(of: try nodeFunction())) (name: \(name ?? "?")) changes from \(previousPort == nil ? "" : BuildEngine.formatOutputPort(previousPort!)) to \(BuildEngine.formatOutputPort(port))")

        try database.outputPort.insertOrUpdate(port)

        for wire in try database.wire.select(comingFromNodeID: id!, fromSymbolID: port.nameSymbolID) {
            var toNode = try database.node.select(nodeID: wire.toNodeID)

            try toNode.writePendingToAllOutputsOfNode()

            if port.valueKind != .pending {
                try toNode.setScheduledAndSave(true)
            }
        }
        return true
    }
}
