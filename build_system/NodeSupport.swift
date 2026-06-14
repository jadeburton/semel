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

    mutating func setNodeFunction(_ nodeFunction: NodeFunction) throws {
        try configuration = nodeFunction.toJSON()
    }

    var allChildren: [Node] {
        get throws {
            try BuildEngine.shared.database.selectNodes(parentNodeID: id!)
        }
    }

    func childNode(path: String, kind: UInt, createIfNotExist: Bool = false) throws -> Node? {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var currentNodeID = id!

        for (index, name) in components.enumerated() {
            guard let rawNode = try? BuildEngine.shared.database.selectNodes(named: name, parentNodeID: currentNodeID).first else {
                if !createIfNotExist {
                    return nil
                }
                // Create

                var node = Node(parentNodeID: currentNodeID,
                                kind: kind,
                                name: name,
                                configuration: try PolyFactory.makeDefault(kind: kind).toJSON(),
                                scheduled: true,
                                searchKey: nil)

                node.id = try DatabaseLayer.shared.insertNode(node)

                return node
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

        let portDeleteCount = try DatabaseLayer.shared.deletePorts(nodeID: id!)

        print("\(portDeleteCount) Port(s) deleted for node #\(id!)")

        //defer { loadedNodes[nodeID] = nil }

        return try DatabaseLayer.shared.deleteNode(nodeID: id!) && portDeleteCount > 0
    }

    static func scheduleNode(nodeID: ObjectID) throws {
        var thisNode = try nodeID.loadNode()
        try thisNode.scheduleNode()
    }

    mutating func scheduleNode() throws {
        scheduled = true
        try DatabaseLayer.shared.updateNode(self)
        BuildEngine.shared.signalWorkAvailable()
    }

    static var projectFinder: Node {
        get throws {
            try Node.rootNode.childNode(path: "projectFinder",
                                        kind: ProjectFinder.kind,
                                        createIfNotExist: true)!
        }
    }

    static var inputFileSystem: Node {
        get throws {
            try Node.rootNode.childNode(path: "inputFileSystem",
                                        kind: Folder.kind,
                                        createIfNotExist: true)!
        }
    }

    static var outputFileSystem: Node {
        get throws {
            try Node.rootNode.childNode(path: "outputFileSystem",
                                        kind: Folder.kind,
                                        createIfNotExist: true)!
        }
    }

    static var rootNode: Node {
        get throws {
            guard let existing = try DatabaseLayer.shared.selectNodesInRoot(named: "root").first else {
                var root = Node(parentNodeID: nil,
                                kind: RootNode.kind,
                                name: "root",
                                configuration: try RootNode().toJSON(),
                                scheduled: true,
                                searchKey: nil)
                
                root.id = try DatabaseLayer.shared.insertNode(root)
                
                return root
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
    func readFromOutputPort(_ outputPort: String) throws -> NodeValue {
        let outputSymbolID = outputPort.asSymbolID()

        guard let port = try DatabaseLayer.shared.selectPort(nodeID: id!, nameSymbolID: outputSymbolID) else {
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
            if let port = try DatabaseLayer.shared.selectPort(nodeID: wire.fromNodeID, nameSymbolID: wire.fromSymbolID) {
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

        if let existing = try DatabaseLayer.shared.selectPort(nodeID: id!, nameSymbolID: port.nameSymbolID) {
            if existing == port {
                print("No change to Port, ignoring")
                return false
            }
        }

        try DatabaseLayer.shared.insertOrUpdatePort(port)

        for wire in try DatabaseLayer.shared.selectWires(comingFromNodeID: id!, fromSymbolID: port.nameSymbolID) {
            var toNode = try wire.toNodeID.loadNode()

            try toNode.writePendingToAllOutputsOfNode()

            if port.valueKind != .pending {
                try toNode.scheduleNode()
            }
        }
        return true
    }
}
