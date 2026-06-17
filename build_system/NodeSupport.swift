//
//  NodeSupport.swift
//  build_system
//
//  Created by Jade Burton on 14.06.26.
//

extension DatabaseLayer {
    static var shared: DatabaseLayer {
        BuildEngine.shared.database
    }
}

extension Node {
    func buildFullPathName(rootName: String = "root") throws -> String {
        let name = name ?? "<no name>"

        guard let parentNodeID = parentNodeID, let parentNode = try DatabaseLayer.shared.selectNodeByID(parentNodeID) else {
            return name
        }

        if parentNode.name == rootName {
            return ""
        }

        let parentPath = try parentNode.buildFullPathName(rootName: rootName)

        return parentPath.isEmpty ? name : (parentPath + "/" + name)
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

    func childNode(path: String) throws -> Node? {
        try childNode(path: path, kind: Folder.kind, createIfNotExist: false, properties: nil)
    }

    static func createNode(parentNodeID: ObjectID?, kind: UInt, name: String, properties: [String: String]?) throws -> Node {

        let type = try PolyFactory.type(kind: kind)

        func make() throws -> InputlessNodeFunction {
            if type is WithProperties.Type {
                if let properties {
                    return try PolyFactory.makeDefault(kind: kind, properties: properties) as InputlessNodeFunction
                } else {
                    return try PolyFactory.makeDefault(kind: kind) 
                }
            } else {
                if properties != nil {
                    throw NodeError.cannotHaveProperties
                }
                return try PolyFactory.makeDefault(kind: kind)
            }
        }

        let nodeFunction = try make()

        var node = Node(parentNodeID: parentNodeID,
                        kind: kind,
                        name: name,
                        configuration: try nodeFunction.toJSON(),
                        scheduled: false,
                        searchKey: nil)

        node.id = try DatabaseLayer.shared.insertNode(node)

        try node.writePendingToAllOutputsOfNode()

        let output = try nodeFunction.didCreate(node: node)
        try nodeFunction.writeToOutputs(output: output, thisNode: node)

//        if nodeFunction is NodeFunction { // don't schedule if it's not a NodeFunction (i.e. if it's just a Folder or similar)
            try node.setScheduledAndSave(true)
//        }

        return node
    }

    func childNode(path: String, kind: UInt, createIfNotExist: Bool = false, properties: [String: String]?) throws -> Node? {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var currentNodeID = id!

        for (index, name) in components.enumerated() {

            guard let rawNode = try? DatabaseLayer.shared.selectNodes(named: name, parentNodeID: currentNodeID).first else {

                if !createIfNotExist {
                    return nil
                }

                return try Self.createNode(parentNodeID: currentNodeID, kind: kind, name: name, properties: properties)
            }

            if index == components.count - 1 {
                return rawNode
            } else {
                currentNodeID = rawNode.id!
            }
        }

        return self
    }

    mutating func insert() throws {
        id = try DatabaseLayer.shared.insertNode(self)
    }

    func delete() throws -> Bool {
        print("delete node #\(id!)")

        for wire in try DatabaseLayer.shared.selectWires(goingToNodeID: id!) {
            _ = try wire.deleteWire()
        }

        for wire in try DatabaseLayer.shared.selectWires(comingFromNodeID: id!) {
            _ = try wire.deleteWire()
        }

        let portDeleteCount = try DatabaseLayer.shared.deleteOutputPorts(nodeID: id!)

        print("\(portDeleteCount) Port(s) deleted for node #\(id!)")

        return try DatabaseLayer.shared.deleteNode(nodeID: id!) && portDeleteCount > 0
    }

    mutating func setScheduledAndSave(_ scheduled: Bool) throws {
        let nodeFunction = try self.nodeFunction()

        guard nodeFunction is NodeFunction else {
            // This NodeFunction has no "process" method and so cannot be scheduled.
            print("Attempted to schedule a \(nodeFunction) that cannot be scheduled. Ignoring.")
            self.scheduled = false
            try DatabaseLayer.shared.updateNode(self)
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
            try Node.rootNode.childNode(path: "projectFinder",
                                        kind: ProjectFinder.kind,
                                        createIfNotExist: true,
                                        properties: nil)!
        }
    }

    static var inputFileSystem: Node {
        get throws {
            try Node.rootNode.childNode(path: "inputFileSystem",
                                        kind: Folder.kind,
                                        createIfNotExist: true,
                                        properties: nil)!
        }
    }

    static var outputFileSystem: Node {
        get throws {
            try Node.rootNode.childNode(path: "outputFileSystem",
                                        kind: Folder.kind,
                                        createIfNotExist: true,
                                        properties: nil)!
        }
    }

    static var rootNode: Node {
        get throws {
            guard let existing = try DatabaseLayer.shared.selectNodesInRoot(named: "root").first else {
                return try Node.createNode(parentNodeID: nil, kind: RootNode.kind, name: "root", properties: nil)
            }

            return existing
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
            try id!.loadNode().writeToOutputPort(outputPort, value: .noValue(reason: .pending))
        }
    }

    @discardableResult func writeToOutputPort(_ outputPort: String, value: NodeValue) throws -> Bool {
        try writeToOutputPort(port: try value.mapPort(nodeID: id!, outputSymbolID: outputPort.asSymbolID()))
    }

    @discardableResult func writeToOutputPort(port: build_system.OutputPort) throws -> Bool {

        if let existing = try DatabaseLayer.shared.selectOutputPort(nodeID: id!, nameSymbolID: port.nameSymbolID) {
            if existing == port {
                //print("No change to Port, ignoring (\(port.nameSymbolID.resolveSymbol()))")
                return false
            }
        }

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
