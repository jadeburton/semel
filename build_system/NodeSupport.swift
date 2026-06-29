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
    func buildFullPathName(baseNodeID: ObjectID?) throws -> String {
        if let baseNodeID {
            if id == baseNodeID {
                return ""
            }
        }

        func parentPath() throws -> String {
            guard let parentNodeID, let parentNode = try DatabaseLayer.shared.selectNodeByID(parentNodeID) else {
                return ""
            }
            return try parentNode.buildFullPathName(baseNodeID: baseNodeID) + "/"
        }

        assert(name == nil || !name!.isEmpty)
        return try parentPath() + (name ?? "<no name>")
    }

    func nodeFunctionCast<N: InputlessNodeFunction>() throws -> N {
        try nodeFunction() as! N
    }

    func nodeFunction() throws -> InputlessNodeFunction {
        try PolyFactory.decode(encodedJSON: configuration!) as! InputlessNodeFunction
    }

    mutating func setNodeFunction(_ nodeFunction: InputlessNodeFunction) throws {
        try configuration = nodeFunction.toJSON()
    }

    var allChildren: [Node] {
        get throws {
            try BuildEngine.shared.database.selectNodes(parentNodeID: id!)
        }
    }

    static func createNode(kind: UInt, properties: [String: String], searchKey: String?) throws -> Node {

        let nodeFunction = try PolyFactory.makeDefault(kind: kind, properties: properties) as InputlessNodeFunction

        var node = Node(parentNodeID: try nodeFunction.initialParentNodeID,
                        kind: kind,
                        name: nodeFunction.initialName,
                        configuration: try nodeFunction.toJSON(),
                        scheduled: false,
                        searchKey: searchKey)

        node.id = try DatabaseLayer.shared.insertNode(node)

        try node.writePendingToAllOutputsOfNode()

        let output = try nodeFunction.didCreate(node: node) ?? nodeFunction.buildErrorOutput(withError: NodeError.initializing)

        try nodeFunction.writeToOutputs(output: output, thisNode: node)

        if nodeFunction is NodeFunction { // don't schedule if it's not a NodeFunction (i.e. if it's just a Folder or similar)
            try node.setScheduledAndSave(true)
        }

        // Patch in cached search key if one was not supplied
        if searchKey == nil {
            do {
                node.searchKey = try GraphShapeNode.buildFromNode(nodeID: node.id!).asString(omitOutputPort: true)
                try DatabaseLayer.shared.updateNode(node)
            } catch {
                print("WARNING: failed to patch-in searchKey (\(error)), are we attempting to create a duplicate Node? searchKey = \(node.searchKey ?? "(null)")")
                throw error
            }
        }

        assert(node.searchKey != nil)
        
        // Locate parent node and notify its NodeFunction of this child's creation
        if let parentNodeID = node.parentNodeID {
            let parentNode = try parentNodeID.loadNode()
            if parentNode.kind == Folder.kind {
                try (parentNode.nodeFunctionCast() as Folder).notifyChildAdded(newChildNode: node, thisNode: parentNode)
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

        var pathSoFar = ""

        for name in components {

            if pathSoFar.isEmpty {
                pathSoFar += name
            } else {
                pathSoFar += "/" + name
            }

            let existingChildren = try DatabaseLayer.shared.selectNodes(named: name, parentNodeID: currentFolder.id!)

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
                var newFolder = try fromNodeID.loadNode()
                newFolder.parentNodeID = currentFolder.id!
                try DatabaseLayer.shared.updateNode(newFolder)

                try (currentFolder.nodeFunctionCast() as Folder).notifyChildAdded(newChildNode: newFolder, thisNode: currentFolder)
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
            guard let childNode = try DatabaseLayer.shared.selectNodes(named: name, parentNodeID: currentNode.id!).first else {
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

        try DatabaseLayer.shared.updateNode(self)

        if scheduled {
            BuildEngine.shared.signalWorkAvailable()
        }
    }

    static var projectFinder: Node {
        get throws {
            let graphShape = GraphShapeNode(typeName: "ProjectFinder", args: [], inputs: [], outputs: [])
            let (fromNodeID, _) = try graphShape.findOrCreateMatchingNode()
            return try fromNodeID.loadNode()
        }
    }

    // TODO: maybe this recurses forever
    static var inputFileSystem: Node {
        get throws {
            let graphShape = GraphShapeNode(typeName: "Folder", args: [.init(key: "path", value: "inputFileSystem")], inputs: [], outputs: [])
            let (fromNodeID, _) = try graphShape.findOrCreateMatchingNode()
            return try fromNodeID.loadNode()
        }
    }

    static var outputFileSystem: Node {
        get throws {
            let graphShape = GraphShapeNode(typeName: "Folder", args: [.init(key: "path", value: "outputFileSystem")], inputs: [], outputs: [])
            let (fromNodeID, _) = try graphShape.findOrCreateMatchingNode()
            return try fromNodeID.loadNode()
        }
    }
}

// MARK: - ObjectID helper

extension ObjectID {
    func loadNode() throws -> Node {
        guard let node = try DatabaseLayer.shared.selectNodeByID(self) else {
            throw DatabaseLayer.DatabaseError.nodeNotFound
        }
        return node
    }
}


// MARK: - Port management

extension Node {
    func hasOneOrMoreErrorOutputs() throws -> Bool {
        try DatabaseLayer.shared.selectAllOutputPorts(nodeID: id!).contains { $0.valueKind != .value }
    }

    func readFromOutputPort(_ outputPort: String) throws -> NodeValue {
        let outputSymbolID = outputPort.asSymbolID()

        guard let port = try DatabaseLayer.shared.selectOutputPort(nodeID: id!, nameSymbolID: outputSymbolID) else {
            return .noValue(reason: .error(message: "No value ever existed"))
        }
        return try port.asNodeValue()
    }

    func readFromInputPort(_ inputPort: String) throws -> [String: NodeValue] {
        let inputSymbolID = inputPort.asSymbolID()

        let wiresOnThisInput = try DatabaseLayer.shared.selectWires(goingToNodeID: id!, toSymbolID: inputSymbolID)

        var result = [String: NodeValue]()

        for wire in wiresOnThisInput {
            let wireName = wire.name.resolveSymbol()
            if let port = try DatabaseLayer.shared.selectOutputPort(nodeID: wire.fromNodeID, nameSymbolID: wire.fromSymbolID) {
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

        if let existing = try DatabaseLayer.shared.selectOutputPort(nodeID: id!, nameSymbolID: port.nameSymbolID) {
            if existing == port {
               // print("No change to Port, ignoring (\(port.nameSymbolID.resolveSymbol()))")
                return false
            }
        }

        //let previousPort = try DatabaseLayer.shared.selectOutputPort(nodeID: id!, nameSymbolID: port.nameSymbolID)
        //print("Output port '\(port.nameSymbolID.resolveSymbol())' of Node #\(id!) \(type(of: try nodeFunction())) (name: \(name ?? "?")) changes from \(previousPort == nil ? "" : BuildEngine.formatOutputPort(previousPort!)) to \(BuildEngine.formatOutputPort(port))")

        try DatabaseLayer.shared.insertOrUpdateOutputPort(port)

        for wire in try DatabaseLayer.shared.selectWires(comingFromNodeID: id!, fromSymbolID: port.nameSymbolID) {
            var toNode = try wire.toNodeID.loadNode()

            try toNode.writePendingToAllOutputsOfNode()

            if port.valueKind != .pending {
                try toNode.setScheduledAndSave(true)
            }
        }
        return true
    }
}
