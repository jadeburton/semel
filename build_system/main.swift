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

let database = try! DatabaseLayer(filePath: "database26.sqlite")

let graph = try! GraphWorld(database: database)

func main() throws {
    try! graph.printAll()
}

enum NodeInputMessageKind {
    case wireConnected(currentValue: DataObject?)
    case wireDisconnected
    case valueMutated(newValue: DataObject?, oldValue: DataObject?)
    case event(dataObject: DataObject)
    case error(description: String)
}

struct NodeInputMessage {
    let originNodeID: ObjectID
    let originOutputPort: UInt8
    let kind: NodeInputMessageKind
}

enum NodeOutputMessage {
    case persistentValue(_ value: DataObject?)
    case event(_ event: DataObject)
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
    let inputs: [PortMetadata]
    let outputs: [PortMetadata]
}

protocol NodeType: AnyObject, Codable {

    init(fromJSONString string: String) throws
    init() throws

    var descriptor: NodeKindDescriptor { get }
    var nodeContext: NodeContext! { get set }

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
    let name: String?

    func saveNode() {
        //try world.saveNode(nodeID: nodeID, node: world.loadNode(nodeID: nodeID) as NodeType)
    }

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
    static let kind: UInt = 0

    var nodeContext: NodeContext!

    // TODO: save/load to configuration
    var dynamicOutputs: [NodeKindDescriptor.PortMetadata] = [.init(name: "output", isOneShot: false, dataType: nil)]

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind,
              kindName: "IngressNode",
              inputs: [],
              outputs: dynamicOutputs)
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
    static let kind: UInt = 1

    var nodeContext: NodeContext!

    var dynamicInputs: [NodeKindDescriptor.PortMetadata] = [.init(name: "input", isOneShot: false, dataType: nil)]

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind,
              kindName: "EgressNode",
              inputs: dynamicInputs,
              outputs: [])
    }

    // This is used by objects outside the Graph to read inputs from connected Nodes inside the Graph.
    func readValues(inputPort: UInt8) throws -> [DataObject?] {
        try nodeContext.readValues(inputPort: inputPort)
    }

    func execute(inputs: [[NodeInputMessage]?]) throws -> [NodeOutputMessage?] {
        []
    }
}


final class StaticFileNode: NodeType {
/*    struct PortInputValues {
        let input: [DataObject?]

        init(inputs: [[NodeInputMessage]?]) {
            self.input = inputs[0]!
        }
    }

    struct PortOutputValues {
        let output: DataObject?
        init() {
            
        }
    }
*/
    var nodeContext: NodeContext!

    let descriptor = NodeKindDescriptor(
        kind: 2,
        kindName: "StaticFileNode",
        inputs: [.init(name: "input", isOneShot: false, dataType: nil)],
        outputs: [.init(name: "output", isOneShot: false, dataType: nil)]
    )

    // If this node receives a write to its one input, it immediately copies the value to its persistent output.
    // The input should not have any one-shot events, only persistent value changes
    func execute(inputs: [[NodeInputMessage]?]) throws -> [NodeOutputMessage?] {
        if inputs.count != descriptor.inputs.count {
            // TODO: throw: invalid number of input messages
            return []
        }

        guard let messagesOnInputPort = inputs.first! else {
            // No messages means no value on this input
            return []
        }

        for message in messagesOnInputPort {
            switch message.kind {

            case .valueMutated(let newValue, _):
                return [.persistentValue(newValue)]

            case .wireConnected(let currentValue):
                return [.persistentValue(currentValue)]

            case .error(let description):
                return [.error(description: description)]

            case .wireDisconnected:
                return [nil]

            case .event(_):
                return [nil]
            }
        }

        return [nil]
    }
}

final class NodeFactory {
    func makeNode<N: NodeType>(kind: UInt, encodedJSON: String?) -> N {
        switch kind {

        case IngressNode.kind: return IngressNode() as! N
        case EgressNode.kind: return EgressNode() as! N

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
        self.egressNode = nil

        // NodeTypes' lifetimes usually transient; created and destroyed during Message processing. However, the Ingress and Egress Nodes are singletons that persist for the entire lifetime of the GraphWorld, since they represent the "edges" of the graph where it interfaces with the outside world.
        //
        // A NodeType's main function is to process Messages. They are deserialized from JSON when loading from the database and reserialized back when done. This preserves internal state of the node such as compiler settings.
        // Creating a NodeType involves instantiating with the initializer that defaults all properties to their "starting" values. Then the object is serialized to the database for the first time.

        ingressNode = try loadOrCreateSingletonNode(kind: 0)
        egressNode = try loadOrCreateSingletonNode(kind: 1)

        try connectWire(fromNodeID: self.ingressNode!.nodeContext.nodeID,
                        fromPort: 0,
                        toNodeID: self.egressNode!.nodeContext.nodeID,
                        toPort: 0)

        try ingressNode!.assignValue(outputPort: 0, dataObjectID: nil)

        try processAllMessages()
    }

    func loadOrCreateSingletonNode<N: NodeType>(kind: UInt) throws -> N {
        if let existingNodeRaw = try database.selectNodes(kind: 1).first {
            return try loadNode(nodeRaw: existingNodeRaw)
        } else {
            let newObject = nodeFactory.makeNode(kind: kind, encodedJSON: nil) as N
            _ = try insertNode(newObject)
            return newObject
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
        let wires = try database.selectWires(comingFromNodeID: nodeID, fromPort: outputPort)

        try database.insertOrReplaceNodeOutputValue(.init(nodeID: nodeID, port: outputPort, dataObjectID: dataObjectID))

        for wire in wires {
            // TODO: prevent more than one queued if the type is valueMutated
            try database.insertMessage(.init(kind: .valueMutated,
                                             targetNodeID: wire.toNodeID,
                                             wireID: wire.id!,
                                             dataObjectID: nil,
                                             priority: 0))
        }
    }

    func postEvent(nodeID: ObjectID, outputPort: UInt8, dataObjectID: ObjectID?) throws {
        let wires = try database.selectWires(comingFromNodeID: nodeID, fromPort: outputPort)

        for wire in wires {
            try database.insertMessage(.init(kind: .event,
                                             targetNodeID: wire.toNodeID,
                                             wireID: wire.id!,
                                             dataObjectID: dataObjectID,
                                             priority: 0))
        }
    }

    func wrapRawNode<N: NodeType>(nodeRaw: Node) throws -> N {
        var node: N = nodeFactory.makeNode(kind: nodeRaw.kind, encodedJSON: nodeRaw.configuration)

        node.nodeContext = NodeContext(world: self,
                                       nodeID: nodeRaw.id!,
                                       name: nodeRaw.name)

        return node
    }

    func loadNode<N: NodeType>(nodeID: ObjectID) throws -> N {
        try wrapRawNode(nodeRaw: nodeID.loadNode(from: database))
    }

    func insertNode<N: NodeType>(_ node: N) throws -> N {
        let nodeID = try database.insertNode(.init(kind: node.descriptor.kind, name: "TODO", configuration: node.asJSONString()))
        return try loadNode(nodeID: nodeID)
    }

//    func saveNode(nodeID: ObjectID, node: NodeType) throws {
//        _ = try database.insertNode(.init(id: nodeID, kind: node.descriptor.kind, name: "TODO", configuration: node.asJSONString()))
//    }

    func connectWire(fromNodeID: ObjectID, fromPort: UInt8, toNodeID: ObjectID, toPort: UInt8) throws {
        guard try database.selectWires(comingFromNodeID: fromNodeID,
                                       fromPort: fromPort,
                                       goingToNodeID: toNodeID,
                                       toPort: toPort).isEmpty else {
            return
        }

        let wireID = try database.insertWire(.init(fromNodeID: fromNodeID, fromPort: fromPort, toNodeID: toNodeID, toPort: toPort))
        try database.insertMessage(.init(kind: .wireConnected, targetNodeID: toNodeID, wireID: wireID, dataObjectID: nil, priority: 0))
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

        return nodes.count > 0
    }

    func processOneNode(_ rawNode: Node) throws {
        let node: NodeType = try wrapRawNode(nodeRaw: rawNode)
        let allRawInputMessages = try database.selectMessages(for: rawNode.id!)
        let rawMessagesGroupedByWireID: Dictionary<ObjectID, [Message]> = Dictionary(grouping: allRawInputMessages, by: { $0.wireID })

        // TODO: group these for execute()
        var inputMessages = [[NodeInputMessage]?]()

//        var wiresOnAllInputs = [Wire]()

        let wiresOnAllInputs = try database.selectWires(goingToNodeID: rawNode.id!)
        let wiresGroupedByInputPort: Dictionary<UInt8, [Wire]> = Dictionary(grouping: wiresOnAllInputs, by: { $0.toPort })

        for inputIndex in 0 ..< node.descriptor.inputs.count {
            let wiresOnInputPort = wiresGroupedByInputPort[UInt8(inputIndex)]!

            var inputMessagesForThisPort = [NodeInputMessage]()

            for wire in wiresOnInputPort {

                for message in rawMessagesGroupedByWireID[wire.id!] ?? [] {

                    let inputMessage: NodeInputMessage

                    switch message.kind {

                    case .wireConnected:
                        let dataObject = try database.selectDataObjectByID(try database.selectNodeOutputValue(nodeID: wire.fromNodeID, port: wire.fromPort)!.dataObjectID!)
                        inputMessage = .init(originNodeID: message.targetNodeID,
                                             originOutputPort: wire.toPort,
                                             kind: .wireConnected(currentValue: dataObject))
                    case .wireDisconnected:
                        inputMessage = .init(originNodeID: message.targetNodeID,
                                             originOutputPort: wire.toPort,
                                             kind: .wireDisconnected)
                    case .valueMutated:
                   //     let dataObject = try database.selectDataObjectByID(try database.selectNodeOutputValue(nodeID: wire.fromNodeID, port: wire.fromPort)!.dataObjectID!)
                        inputMessage = .init(originNodeID: message.targetNodeID,
                                             originOutputPort: wire.toPort,
                                             kind: .valueMutated(newValue: /*dataObject*/nil, oldValue: nil))
                    case .event:
                        inputMessage = .init(originNodeID: message.targetNodeID,
                                             originOutputPort: wire.toPort,
                                             kind: .event(dataObject: try database.selectDataObjectByID(message.dataObjectID!)!))
                    case .error:
                        inputMessage = .init(originNodeID: message.targetNodeID,
                                             originOutputPort: wire.toPort,
                                             kind: .error(description: "TODO"))

                    }
                    inputMessagesForThisPort.append(inputMessage)
                }
                
                inputMessages.append(inputMessagesForThisPort)
            }
        }

        let outputs = try node.execute(inputs: inputMessages)

        // Send all outputs down the output wires
        try writeToAllOutputs(outputs, node: node)

        try deleteAllInputMessages(allRawInputMessages)
    }


    func writeToAllOutputs(_ messages: [NodeOutputMessage?], node: NodeType) throws {
        var outputIndex = 0
        for message in messages {

            let wiresOnThisOutput: [Wire] = try database.selectWires(comingFromNodeID: node.nodeContext.nodeID,
                                                                     fromPort: UInt8(outputIndex))

           // let outputDescriptor = node.descriptor.outputs[outputIndex]

            if let message {
                switch message {

                case .persistentValue(let value):
                    for wire in wiresOnThisOutput {
                        try database.insertOrReplaceNodeOutputValue(.init(nodeID: node.nodeContext.nodeID, port: UInt8(outputIndex), dataObjectID: value?.id))
                        
                        let rawMessage = Message(kind: .valueMutated,
                                                 targetNodeID: wire.toNodeID,
                                                 wireID: wire.id!,
                                                 dataObjectID: nil,
                                                 priority: 0)
                        try database.insertMessage(rawMessage)
                    }

                case .event(let dataObject):
                    for wire in wiresOnThisOutput {
                        let rawMessage = Message(kind: .event,
                                                 targetNodeID: wire.toNodeID,
                                                 wireID: wire.id!,
                                                 dataObjectID: dataObject.id,
                                                 priority: 0)
                        try database.insertMessage(rawMessage)
                    }

                case .error(let description):
                    for wire in wiresOnThisOutput {
                        let rawMessage = Message(kind: .error,
                                                 targetNodeID: wire.toNodeID,
                                                 wireID: wire.id!,
                                                 dataObjectID: nil,
                                                 priority: 0)
                        try database.insertMessage(rawMessage)
                    }

                }
            }

            outputIndex += 1
        }
    }

    func deleteAllInputMessages(_ inputMessages: [Message]) throws {
        for message in inputMessages {
            _ = try database.deleteMessage(messageID: message.id!) // TODO: error handling
        }
    }
}

extension NodeType {
    init(fromJSONString string: String) throws {
        self = try Self.fromJSONString(string)
    }

    static func fromJSONString(_ string: String) throws -> Self {
        let decoder = JSONDecoder()
        let data = string.data(using: .utf8)!
        return try decoder.decode(Self.self, from: data)
    }

    func asJSONString() throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8)!
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
