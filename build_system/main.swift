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

let database = try! DatabaseLayer(filePath: "database25.sqlite")

let graph = try! GraphWorld(database: database)

func main() throws {
    try! graph.printAll()
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
    case customEvent(_ event: DataObject)
    case error(description: String)
}

struct NodeKindDescriptor {
    struct PortMetadata {
        let name: String
        let isOneShot: Bool
        let dataType: String?
    }

    let kind: UInt
    let kindName: String

    // When nil, these are dynamically determined.
    let inputs: [PortMetadata]?
    let outputs: [PortMetadata]?
}

protocol NodeType: AnyObject {

    static var descriptor: NodeKindDescriptor { get }

    init(nodeContext: NodeContext)
    func makeConfiguration() -> String?

    func execute(inputs: [[NodeInputMessage]?]) throws -> [NodeOutputMessage?]
}

protocol World {
    var database: DatabaseLayer { get }

    func readValues(nodeID: ObjectID, inputPort: UInt8) throws -> [DataObject?] 
    func assignValue(nodeID: ObjectID, outputPort: UInt8, dataObjectID: ObjectID?) throws
    func postEvent(nodeID: ObjectID, outputPort: UInt8, dataObjectID: ObjectID?) throws

}

struct NodeContext {
    let world: World
    let nodeID: ObjectID
    let configuration: String?

    func readValues(inputPort: UInt8) throws -> [DataObject?] {
        try world.readValues(nodeID: nodeID, inputPort: inputPort)
    }

    func assignValue(outputPort: UInt8, dataObjectID: ObjectID?) throws {
        try world.assignValue(nodeID: nodeID, outputPort: outputPort, dataObjectID: dataObjectID)
    }

    func postEvent(outputPort: UInt8, dataObjectID: ObjectID?) throws {
        try world.postEvent(nodeID: nodeID, outputPort: outputPort, dataObjectID: dataObjectID)
    }
}

final class IngressNode: NodeType {
    static let descriptor = NodeKindDescriptor(
        kind: 0,
        kindName: "IngressNode",
        inputs: [],
        outputs: nil
    )

    let nodeContext: NodeContext

    init(nodeContext: NodeContext) {
        self.nodeContext = nodeContext
    }

    func makeConfiguration() -> String? {
        nil
    }

    func assignValue(outputPort: UInt8, dataObjectID: ObjectID?) throws {
        try nodeContext.assignValue(outputPort: outputPort, dataObjectID: dataObjectID)
    }

    func postEvent(outputPort: UInt8, dataObjectID: ObjectID?) throws {
        try nodeContext.postEvent(outputPort: outputPort, dataObjectID: dataObjectID)
    }

    func execute(inputs: [[NodeInputMessage]?]) throws -> [NodeOutputMessage?] {
        []
    }
}

final class EgressNode: NodeType {
    static let descriptor = NodeKindDescriptor(
        kind: 1,
        kindName: "EgressNode",
        inputs: nil,
        outputs: []
    )

    let nodeContext: NodeContext

    init(nodeContext: NodeContext) {
        self.nodeContext = nodeContext
    }

    func makeConfiguration() -> String? {
        nil
    }

    func readValues(inputPort: UInt8) throws -> [DataObject?] {
        try nodeContext.readValues(inputPort: inputPort)
    }

    func execute(inputs: [[NodeInputMessage]?]) throws -> [NodeOutputMessage?] {
        []
    }
}

final class StaticFileNode: NodeType {
    static let descriptor = NodeKindDescriptor(
        kind: 2,
        kindName: "StaticFileNode",
        inputs: [.init(name: "input", isOneShot: false, dataType: nil)],
        outputs: [.init(name: "output", isOneShot: false, dataType: nil)]
    )

    let nodeContext: NodeContext

    init(nodeContext: NodeContext) {
        self.nodeContext = nodeContext
    }

    func makeConfiguration() -> String? {
        nil
    }

    // If this node receives a write to its one input, it immediately copies the value to its persistent output.
    // The input should not have any one-shot events, only persistent value changes
    func execute(inputs: [[NodeInputMessage]?]) throws -> [NodeOutputMessage?] {
        if inputs.count != Self.descriptor.inputs!.count {
            // TODO: throw: invalid number of input messages
            return []
        }

        guard let messagesOnInputPort = inputs.first! else {
            // No messages means no value on this input
            return []
        }

        for message in messagesOnInputPort {
            switch message.kind {

            case .inputChanged(let newValue, _):
                return [.persistentValue(newValue)]

            case .didConnect(let currentValue):
                return [.persistentValue(currentValue)]

            case .error(let description):
                return [.error(description: description)]

            case .willDisconnect:
                return [nil]

            case .customEvent(_):
                return [nil]
            }
        }

        return [nil]
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
    var ingressNode: IngressNode?
    var egressNode: EgressNode?

    init(database: DatabaseLayer, nodeFactory: NodeFactory = NodeFactory()) throws {
        self.database = database
        self.nodeFactory = nodeFactory

        self.ingressNode = nil
        self.egressNode = nil

        if let node = try database.selectNodes(kind: 0).first {
            let nodeContext = NodeContext(world: self, nodeID: node.id!, configuration: node.configuration)
            self.ingressNode = (nodeFactory.makeNode(nodeContext: nodeContext, kind: 0) as! IngressNode)
        } else {
            let nodeID = try database.insertNode(Node(kind: 0, name: "Ingress", configuration: nil))
            let nodeContext = NodeContext(world: self, nodeID: nodeID, configuration: nil)
            self.ingressNode = .init(nodeContext: nodeContext)
        }

        if let node = try database.selectNodes(kind: 1).first {
            let nodeContext = NodeContext(world: self, nodeID: node.id!, configuration: node.configuration)
            self.egressNode = (nodeFactory.makeNode(nodeContext: nodeContext, kind: 1) as! EgressNode)
        } else {
            let nodeID = try database.insertNode(Node(kind: 1, name: "Egress", configuration: nil))
            let nodeContext = NodeContext(world: self, nodeID: nodeID, configuration: nil)
            self.egressNode = .init(nodeContext: nodeContext)
        }

        try connectWire(fromNodeID: self.ingressNode!.nodeContext.nodeID,
                    fromPort: 0,
                    toNodeID: self.egressNode!.nodeContext.nodeID,
                    toPort: 0)

        try ingressNode!.assignValue(outputPort: 0, dataObjectID: nil)

        try processAllMessages()
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
        let wires = try database.selectWires(comingFromNodeID: nodeID, fromPort: outputPort)

        try database.insertOrReplaceNodeOutputValue(.init(nodeID: nodeID, port: outputPort, dataObjectID: dataObjectID))

        for wire in wires {
            // TODO: prevent more than one queued if the type is persistent-value-change
            try database.insertMessage(.init(targetNodeID: wire.toNodeID, targetPort: wire.toPort, oneShotDataObjectID: nil, priority: 0))
        }
    }

    func postEvent(nodeID: ObjectID, outputPort: UInt8, dataObjectID: ObjectID?) throws {
        let wires = try database.selectWires(comingFromNodeID: nodeID, fromPort: outputPort)

        for wire in wires {
            try database.insertMessage(.init(targetNodeID: wire.toNodeID, targetPort: wire.toPort, oneShotDataObjectID: dataObjectID, priority: 0))
        }
    }

    func loadNode(nodeID: ObjectID) throws -> NodeType {
        let node = try nodeID.loadNode(from: database)
        return nodeFactory.makeNode(nodeContext: .init(world: self, nodeID: nodeID, configuration: node.configuration), kind: node.kind)
    }

    func saveNode(nodeID: ObjectID, node: NodeType) throws {
        _ = try database.insertNode(.init(id: nodeID, kind: type(of: node).descriptor.kind, name: "TODO", configuration: node.makeConfiguration()))
    }

    func connectWire(fromNodeID: ObjectID, fromPort: UInt8, toNodeID: ObjectID, toPort: UInt8) throws {
        guard try database.selectWires(comingFromNodeID: fromNodeID,
                                       fromPort: fromPort,
                                       goingToNodeID: toNodeID,
                                       toPort: toPort).isEmpty else {
            return
        }
        try database.insertWire(.init(fromNodeID: fromNodeID, fromPort: fromPort, toNodeID: toNodeID, toPort: toPort))
    }

    func printAll() throws {
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

        print("")

        for message in try database.selectAllMessages(limit: 10000) {
            print("Message ID: \(message.description())")
        }

        print("")
        for dataObject in try database.selectAllDataObjects() {
            print("DataObject ID: \(dataObject.description())")
        }

    }

    func processAllMessages() throws {
        while try processSomeMessages() {
        }
    }

    func processSomeMessages() throws -> Bool {
        let nodes = try database.selectAllNodesWithInputMessages(limit: 10)

        for node in nodes {
            try processOneNode(node) // TODO: catch
        }

        return messages.count > 0
    }

    func processOneNode(_ node: Node) throws {
        // Identify the Node.
        // Load the Node's type and configuration.
        let node = try loadNode(nodeID: message.targetNodeID)
        // Load the Node's input values.
        // Execute the Node's logic, passing in queued messages per input, as well as pulled persisted values if available.
        let wiresOnAllInputs = try database.selectWires(goingToNodeID: message.targetNodeID)

        let inputCount = type(of: node).descriptor.inputs?.count ?? 0
        let outputCount = type(of: node).descriptor.outputs?.count ?? 0

        let wiresGroupedByInputPort: Dictionary<UInt8, [Wire]> = Dictionary(grouping: wiresOnAllInputs, by: { $0.toPort })

        let outputs = try node.execute(inputs: readAllInputMessages(for: node))

        // Write all outputs to output wires
        writeAllOutputs(outputs, node: node)
        
        // TODO: this will break outer for loop
        deleteAllInputMessages(nodeID: message.targetNodeID, inputPort: message.targetPort)
    }

    func readAllInputMessages(for node: NodeType) throws -> [[NodeInputMessage]?] {
        var inputs = [[NodeInputMessage]?](repeating: nil, count: inputCount)

        for inputIndex in 0 ..< inputCount {
            let wiresConnectingToPort = wiresGroupedByInputPort[UInt8(inputIndex)] ?? []

//            inputs[inputIndex] = wiresConnectingToPort.map { wire in
//                nil // TODO!
//            }
        }

        return inputs
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
