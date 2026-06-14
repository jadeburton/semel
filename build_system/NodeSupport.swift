//
//  NodeSupport.swift
//  build_system
//
//  Created by Jade Burton on 14.06.26.
//

extension Node {
    func buildFullPathName(rootName: String = "root", database: DatabaseLayer) throws -> String {
        let name = name ?? "<no name>"

        guard let parentNodeID = parentNodeID, let parentNode = try database.selectNodeByID(parentNodeID) else {
            return name
        }

        if parentNode.name == rootName {
            return ""
        }

        let parentPath = try parentNode.buildFullPathName(rootName: rootName, database: database)

        return parentPath.isEmpty ? name : (parentPath + "/" + name)
    }

    func nodeFunctionCast<N: NodeFunction>() throws -> N {
        try nodeFunction() as! N
    }

    func nodeFunction() throws -> NodeFunction {
        try PolyFactory.decode(encodedJSON: configuration!) as! NodeFunction
    }

    mutating func setNodeFunction(_ nodeFunction: NodeFunction) throws {
        try configuration = nodeFunction.toJSON()
    }

    func childNode(path: String, rootNodeID: ObjectID, kind: UInt, createIfNotExist: Bool = false, database: DatabaseLayer) throws -> Node? {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var currentNodeID = rootNodeID

        for (index, name) in components.enumerated() {
            guard let rawNode = try? database.selectNodes(named: name, parentNodeID: currentNodeID).first else {
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

                node.id = try database.insertNode(node)

                return node
            }

            if index == components.count - 1 {
                return rawNode
            } else {
                currentNodeID = rawNode.id!
            }
        }

        return try rootNodeID.loadNode(from: database)
    }

    mutating func insert(database: DatabaseLayer) throws {
        id = try database.insertNode(self)
    }

    func delete(database: DatabaseLayer) throws -> Bool {
        print("delete node #\(id!)")

        for wire in try database.selectWires(goingToNodeID: id!) {
            _ = try wire.deleteWire(database: database)
        }

        for wire in try database.selectWires(comingFromNodeID: id!) {
            _ = try wire.deleteWire(database: database)
        }

        let portDeleteCount = try database.deletePorts(nodeID: id!)

        print("\(portDeleteCount) Port(s) deleted for node #\(id!)")

        //defer { loadedNodes[nodeID] = nil }

        return try database.deleteNode(nodeID: id!) && portDeleteCount > 0
    }

    static func scheduleNode(nodeID: ObjectID, database: DatabaseLayer) throws {
        var thisNode = try nodeID.loadNode(from: database)
        try thisNode.scheduleNode(database: database)
    }

    mutating func scheduleNode(database: DatabaseLayer) throws {
        scheduled = true
        try database.updateNode(self)
        BuildEngine.shared.signalWorkAvailable()
    }

    static func rootNode(database: DatabaseLayer) throws -> Node {
        guard let existing = try database.selectNodesInRoot(named: "root").first else {
            var root = Node(parentNodeID: nil,
                            kind: RootNode.kind,
                            name: "root",
                            configuration: try RootNode().toJSON(),
                            scheduled: true,
                            searchKey: nil)

            root.id = try database.insertNode(root)

            return root
        }

        return existing
    }
}

// MARK: - ObjectID helper

extension ObjectID {
    func loadNode(from database: DatabaseLayer) throws -> Node {
        guard let node = try database.selectNodeByID(self) else {
            throw DatabaseLayer.DatabaseError.nodeNotFound
        }
        return node
    }
}


// MARK: - Port management

extension Node {
    func readFromOutputPort(_ outputPort: String, database: DatabaseLayer) throws -> NodeValue {
        let outputSymbolID = outputPort.asSymbolID()

        guard let port = try database.selectPort(nodeID: id!, nameSymbolID: outputSymbolID) else {
            return .noValue(reason: .error(message: "No value ever existed"))
        }
        return try port.asNodeValue()
    }

    func readFromInputPort(_ inputPort: String, database: DatabaseLayer) throws -> [String: NodeValue] {
        let inputSymbolID = inputPort.asSymbolID()

        let wiresOnThisInput = try database.selectWires(goingToNodeID: id!, toSymbolID: inputSymbolID)

        var result = [String: NodeValue]()

        for wire in wiresOnThisInput {
            let wireName = wire.name.resolveSymbol()
            if let port = try database.selectPort(nodeID: wire.fromNodeID, nameSymbolID: wire.fromSymbolID) {
                assert(result[wireName] == nil) // all wires must have unique names
                try result[wireName] = port.asNodeValue()
            }
        }

        return result
    }

    func writePendingToAllOutputsOfNode(database: DatabaseLayer) throws {
        for outputPort in try nodeFunction().descriptor.outputPorts {
            try Node.writeToOutputPort(outputPort, value: .noValue(reason: .pending), nodeID: id!, database: database)
        }
    }

    @discardableResult func writeToOutputPort(_ outputPort: String,
                                              value: NodeValue,
                                              database: DatabaseLayer) throws -> Bool {

        try writeToOutputPort(port: try value.mapPort(nodeID: id!, outputSymbolID: outputPort.asSymbolID()),
                              database: database)
    }

    @discardableResult func writeToOutputPort(port: build_system.OutputPort,
                                              database: DatabaseLayer) throws -> Bool {

        if let existing = try database.selectPort(nodeID: id!, nameSymbolID: port.nameSymbolID) {
            if existing == port {
                print("No change to Port, ignoring")
                return false
            }
        }

        try database.insertOrUpdatePort(port)

        for wire in try database.selectWires(comingFromNodeID: id!, fromSymbolID: port.nameSymbolID) {
            var toNode = try wire.toNodeID.loadNode(from: database)

            try toNode.writePendingToAllOutputsOfNode(database: database)

            if port.valueKind != .pending {
                try toNode.scheduleNode(database: database)
            }
        }
        return true
    }
}
