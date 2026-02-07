//
//  main.swift
//  build_system
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import GRDB
import DatabaseModels

extension Database {
    func removeAllWiresBetweenNodes(firstNodeID: ObjectID, secondNodeID: ObjectID) throws {
    }
}

let database = try! DatabaseLayer(filePath: "database23.sqlite")

let graph = try! GraphWorld(database: database)

func main() throws {
    try! graph.printAllNodes()
}

enum NodeInputMessageKind {
    case didConnect(currentValue: DataObject?)
    case willDisconnect
    case inputChanged(newValue: DataObject?, oldValue: DataObject?)
    case error(description: String)
    case customEvent(dataObject: DataObject)
}

struct NodeInputMessage {
    let originNodeID: ObjectID
    let originOutputPort: UInt8
    let kind: NodeInputMessageKind
}

enum NodeOutputMessage {
    case persistentValue(_ value: DataObject?)
    case event(_ event: DataObject)
}

protocol NodeType {
    var kind: UInt { get }
    var inputCount: UInt8 { get }
    var outputCount: UInt8 { get }

    init(nodeContext: NodeContext)
    func makeConfiguration() -> String?

    func execute(inputs: [[NodeInputMessage?]]) throws -> [NodeOutputMessage]
}

protocol World {
    var database: DatabaseLayer { get }

    func readValues(nodeID: ObjectID, inputPort: UInt8) throws -> [DataObject?] 
    func assignValue(nodeID: ObjectID, outputPort: UInt8, dataObjectID: ObjectID?) throws
    func postEvent(nodeID: ObjectID, outputPort: UInt8, event: DataObject) throws

}

struct NodeContext {
    let world: World
    let nodeID: ObjectID
    let configuration: String?

    func readValues(inputPort: UInt8) throws -> [DataObject?] {
        try world.readValues(nodeID: nodeID, inputPort: inputPort)
    }

    func assignValue(nodeID: ObjectID, outputPort: UInt8, dataObjectID: ObjectID?) throws {
        try world.assignValue(nodeID: nodeID, outputPort: outputPort, dataObjectID: dataObjectID)
    }

    func postEvent(outputPort: UInt8, event: DataObject) throws {
        try world.postEvent(nodeID: nodeID, outputPort: outputPort, event: event)
    }
}

final class IngressNode: NodeType {
    let kind: UInt = 0
    let inputCount: UInt8 = 0
    var outputCount: UInt8 = 1
    let nodeContext: NodeContext

    init(nodeContext: NodeContext) {
        self.nodeContext = nodeContext
    }

    func makeConfiguration() -> String? {
        nodeContext.configuration
    }

    func assignValue(outputPort: UInt8, dataObjectID: ObjectID?) throws {
        try nodeContext.assignValue(nodeID: nodeContext.nodeID, outputPort: outputPort, dataObjectID: dataObjectID)
    }

    func postEvent(outputPort: UInt8, event: DataObject) throws {
        try nodeContext.postEvent(outputPort: outputPort, event: event)
    }

    func execute(inputs: [[NodeInputMessage?]]) throws -> [NodeOutputMessage] {
        []
    }
}

final class EgressNode: NodeType {
    let kind: UInt = 1
    var inputCount: UInt8 = 1
    let outputCount: UInt8 = 0
    let nodeContext: NodeContext

    init(nodeContext: NodeContext) {
        self.nodeContext = nodeContext
    }

    func makeConfiguration() -> String? {
        nodeContext.configuration
    }

    func readValues(inputPort: UInt8) throws -> [DataObject?] {
        try nodeContext.readValues(inputPort: inputPort)
    }

    func execute(inputs: [[NodeInputMessage?]]) throws -> [NodeOutputMessage] {
        []
    }
}

final class NodeFactory {
    func makeNode(nodeContext: NodeContext, kind: UInt) -> NodeType {
        switch kind {

        case 0: return IngressNode(nodeContext: nodeContext)
        case 1: return EgressNode(nodeContext: nodeContext)

        default:
            fatalError("Unknown Node kind: \(kind)")
            break
        }
    }
}

final class GraphWorld: World {
    let database: DatabaseLayer
    let nodeFactory: NodeFactory

    init(database: DatabaseLayer, nodeFactory: NodeFactory = NodeFactory()) throws {
        self.database = database
        self.nodeFactory = nodeFactory
        try ensureIngressAndEgressExist()
    }

    func ensureIngressAndEgressExist() throws {
        if try database.selectNodes(kind: 0).count == 0 {
            try database.insertNode(.init(kind: 0, name: "Ingress", configuration: nil))
        }
        if try database.selectNodes(kind: 1).count == 0 {
            try database.insertNode(.init(kind: 1, name: "Egress", configuration: nil))
        }
    }

    func readValues(nodeID: ObjectID, inputPort: UInt8) throws -> [DataObject?] {
        let wires = try database.selectWires(goingToNodeID: nodeID, toPort: inputPort)

        return try wires.map { wire in
            let fromNodeID = wire.fromNodeID
            let fromPort = wire.fromPort

            let nodeOutputValue = try database.selectNodeOutputValue(nodeID: fromNodeID, port: fromPort)

            if let dataObjectID = nodeOutputValue?.dataObjectID {
                return try database.selectDataObjectByID(dataObjectID)
            }

            return nil
        }
    }

    func assignValue(nodeID: ObjectID, outputPort: UInt8, dataObjectID: ObjectID?) throws {
        let wires = try database.selectWires(comingFromNodeID: nodeID)

        try database.insertOrReplaceNodeOutputValue(.init(nodeID: nodeID, port: outputPort, dataObjectID: dataObjectID))

        for wire in wires {
            try database.insertMessage(.init(targetNodeID: wire.toNodeID, targetPort: wire.toPort, oneShotDataObjectID: nil, priority: 0))
        }
    }

    func postEvent(nodeID: ObjectID, outputPort: UInt8, event: DataObject) throws {
        
    }

    func loadNode(nodeID: ObjectID) throws -> NodeType {
        let node = try nodeID.loadNode(from: database)
        return nodeFactory.makeNode(nodeContext: .init(world: self, nodeID: nodeID, configuration: node.configuration), kind: node.kind)
    }

    func saveNode(nodeID: ObjectID, node: NodeType) throws {
        try database.insertNode(.init(id: nodeID, kind: node.kind, name: "TODO", configuration: node.makeConfiguration()))
    }

    func printAllNodes() throws {
        for node in try database.selectAllNodes() {
            print("Node ID: \(node.description())")

            for wire in try database.selectWires(goingToNodeID: node.id!) {
                let fromDesc = try? wire.fromNodeID.loadNode(from: database).description()
                print("    Wire (\(wire.id ?? -1)) from port \(wire.fromPort): \(fromDesc ?? "<unknown>")")
            }
            for wire in try database.selectWires(comingFromNodeID: node.id!) {
                let toDesc = try? wire.toNodeID.loadNode(from: database).description()
                print("    Wire (\(wire.id ?? -1)) to port \(wire.toPort): \(toDesc ?? "<unknown>")")
            }
        }
    }
}

try main()

extension ObjectID {
    func loadNode(from database: DatabaseLayer) throws -> Node {
        guard let node = try database.selectNodeByID(self) else {
            throw DatabaseLayer.DatabaseError.nodeNotFound
        }
        return node
    }
}
