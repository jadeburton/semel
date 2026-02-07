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

let database = try! DatabaseLayer(filePath: "database28.sqlite")

let graph = try! GraphWorld(database: database)

func main() throws {
    _ = graph
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
    case valueMutation(_ value: DataObject?)
    case event(_ event: DataObject)
    case error(description: String)
}

enum PortValueDataType: Codable, Hashable {
    case utf8Text
    case binary
    case json
    case custom(dataTypeName: String)
}

struct NodeKindDescriptor {
    enum PortKind: Codable, Hashable {
        case persistentValue(dataType: PortValueDataType)
        case oneShotEvent
    }

    struct Port: Codable, Hashable {
        let index: UInt8
        let name: String
        let kind: PortKind
    }

    let kind: UInt
    let inputs: [Port]
    let outputs: [Port]
}

typealias DataToken = ObjectID

extension [UInt8] {
    func intern() -> DataToken {
        let hash = Sha256.hash(self)
        if let existingDataObjectID = try! DatabaseLayer.shared.selectDataObjectID(hash: hash) {
            return existingDataObjectID
        } else {
            return try! DatabaseLayer.shared.insertDataObject(DataObject(hash: hash, content: self))
        }
    }
}

extension DataToken {
    func resolve() -> [UInt8]? {
        (try? DatabaseLayer.shared.selectDataObjectByID(self))?.content
    }
}

extension NodeType {
    func assignValue(outputPort: NodeKindDescriptor.Port, value: DataToken?) throws {
        try nodeContext.assignValue(outputPort: outputPort.index, dataObjectID: value)
    }

    func postEvent(outputPort: NodeKindDescriptor.Port, eventData: DataToken?) throws {
        try nodeContext.postEvent(outputPort: outputPort.index, dataObjectID: eventData)
    }
}

protocol NodeType: AnyObject, Codable {

    init() throws

    var descriptor: NodeKindDescriptor { get }
    var nodeContext: NodeContext! { get set }

    func processInputs(_ inputs: [NodeKindDescriptor.Port: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.Port: NodeOutputMessage?]
}

protocol World {
    var database: DatabaseLayer { get }

    func readValues(nodeID: ObjectID, inputPort: UInt8) throws -> [DataObject?]
    func assignValue(nodeID: ObjectID, outputPort: UInt8, dataObjectID: ObjectID?) throws
    func postEvent(nodeID: ObjectID, outputPort: UInt8, dataObjectID: ObjectID?) throws

}

struct NodeContext {
    let world: World
    var nodeID: ObjectID? // nil when created in memory but not yet inserted
    var name: String?

    func updateNode() {
//        try world.saveNode(nodeID: nodeID, node: self, name: name)
    }

    func readValues(inputPort: UInt8) throws -> [DataObject?] {
        try world.readValues(nodeID: nodeID!, inputPort: inputPort)
    }

    func assignValue(outputPort: UInt8, dataObjectID: ObjectID?) throws {
        try world.assignValue(nodeID: nodeID!, outputPort: outputPort, dataObjectID: dataObjectID)
    }

    func postEvent(outputPort: UInt8, dataObjectID: ObjectID?) throws {
        try world.postEvent(nodeID: nodeID!, outputPort: outputPort, dataObjectID: dataObjectID)
    }
}

final class IngressNode: NodeType {
    static let kind: UInt = 0

    var nodeContext: NodeContext!
    var dynamicOutputs: [NodeKindDescriptor.Port]

    enum CodingKeys: String, CodingKey {
        case dynamicOutputs
    }

    required init() {
        dynamicOutputs = [
            .init(index: 0, name: "output", kind: .persistentValue(dataType: .binary))
        ]
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dynamicOutputs = try container.decode([NodeKindDescriptor.Port].self, forKey: .dynamicOutputs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dynamicOutputs, forKey: .dynamicOutputs)
    }

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [], outputs: dynamicOutputs)
    }

    func processInputs(_ inputs: [NodeKindDescriptor.Port: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.Port: NodeOutputMessage?] {
        [:]
    }
}

final class EgressNode: NodeType {
    static let kind: UInt = 1

    var nodeContext: NodeContext!
    var dynamicInputs: [NodeKindDescriptor.Port]

    enum CodingKeys: String, CodingKey {
        case dynamicInputs
    }

    required init() {
        dynamicInputs = [
            .init(index: 0, name: "input", kind: .persistentValue(dataType: .binary))
        ]
    }

    // Adds a new input port effectively to the entire Graph
    func addInputPort(named name: String, kind: NodeKindDescriptor.PortKind) {
        dynamicInputs.append(.init(index: UInt8(dynamicInputs.count), name: name, kind: kind))
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dynamicInputs = try container.decode([NodeKindDescriptor.Port].self, forKey: .dynamicInputs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dynamicInputs, forKey: .dynamicInputs)
    }

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: dynamicInputs, outputs: [])
    }

    func processInputs(_ inputs: [NodeKindDescriptor.Port: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.Port: NodeOutputMessage?] {
        [:]
    }
}

final class StaticFileNode: NodeType {

    static let kind: UInt = 2
    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {
    }

    required init() {
    }

    required init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
        // StaticFileNode has no stored properties to decode (nodeContext is set separately)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
        // StaticFileNode has no stored properties to encode (nodeContext is not encoded)
    }

    static let inputPort = NodeKindDescriptor.Port(index: 0, name: "input", kind: .persistentValue(dataType: .utf8Text))
    static let outputPort = NodeKindDescriptor.Port(index: 0, name: "output", kind: .persistentValue(dataType: .utf8Text))

    static let descriptor = NodeKindDescriptor(kind: kind, inputs: [inputPort], outputs: [outputPort])

    var descriptor: NodeKindDescriptor {
        Self.descriptor
    }

    // If this node receives a write to its one input, it immediately copies the value to its persistent output.
    // The input should not have any one-shot events, only persistent value changes
    func processInputs(_ inputs: [NodeKindDescriptor.Port: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.Port: NodeOutputMessage?] {
        assert(inputs.count == descriptor.inputs.count)

        guard let messagesOnInputPort = inputs[Self.inputPort]! else {
            // No messages means no value on this input
            return [:]
        }

        guard let oneMessageOnInputPort = messagesOnInputPort.first, messagesOnInputPort.count == 1 else {
            // More than one message queued - should be impossible
            return [:]
        }

        func outputValue() -> NodeOutputMessage? {
            switch oneMessageOnInputPort.kind {

            case .valueMutated(let newValue, _):
                print("StaticFileNode received new value: [\(newValue?.content.asHex() ?? "nil")]")
                return .valueMutation(newValue)

            case .wireConnected(let currentValue):
                print("StaticFileNode received new wire")
                return .valueMutation(currentValue)

            case .error(let description):
                print("StaticFileNode received error")
                return .error(description: description)

            case .wireDisconnected:
                print("StaticFileNode lost input wire")
                return nil

            case .event(_):
                // This should not be possible, since the input port is not an event port, but if it happens, we just ignore it
                print("StaticFileNode got an event")
                return nil
            }
        }

        return [Self.outputPort: outputValue()]
    }
}

final class NodeFactory {
    func makeNode(kind: UInt, encodedJSON: String?) throws -> NodeType {
        switch kind {

        case IngressNode.kind: return try IngressNode.fromJSONString(encodedJSON)
        case EgressNode.kind: return try EgressNode.fromJSONString(encodedJSON)
        case StaticFileNode.kind: return try StaticFileNode.fromJSONString(encodedJSON)

        default:
            fatalError("Unknown Node kind: \(kind)")
            break
        }
    }
}

extension DatabaseLayer {
    fileprivate func connectWire(fromNodeID: ObjectID, fromPort: UInt8, toNodeID: ObjectID, toPort: UInt8) throws {
        guard try database.selectWires(comingFromNodeID: fromNodeID,
                                       fromPort: fromPort,
                                       goingToNodeID: toNodeID,
                                       toPort: toPort).isEmpty else {
            return
        }

        // TODO: transactional
        // TODO: if there is a circular reference, block the creation of the Wire
        let wireID = try database.insertWire(.init(fromNodeID: fromNodeID, fromPort: fromPort, toNodeID: toNodeID, toPort: toPort))
        try database.insertMessage(.init(kind: .wireConnected, targetNodeID: toNodeID, wireID: wireID, dataObjectID: nil, priority: 0))
    }
}

final class GraphWorld: World {
    let database: DatabaseLayer
    let nodeFactory: NodeFactory
    var ingressNode: IngressNode!
    var egressNode: EgressNode!

    init(database: DatabaseLayer, nodeFactory: NodeFactory = NodeFactory()) throws {
        self.database = database
        self.nodeFactory = nodeFactory
        self.egressNode = nil

        ingressNode = try loadOrCreateSingletonNode(kind: IngressNode.kind, name: "Ingress")
        egressNode = try loadOrCreateSingletonNode(kind: EgressNode.kind, name: "Egress")
/*
        try connectWire(fromNode: self.ingressNode!,
                        fromPort: 0,
                        toNode: self.egressNode!,
                        toPort: 0)
*/
      //  let staticFileNode = try makeNode(kind: StaticFileNode.kind, name: "StaticFile") as! StaticFileNode
      //  staticFileNode.nodeContext.nodeID = try insertNode(staticFileNode)
/*
        _ = try deleteWire(fromNode: self.ingressNode!,
                           fromPort: 0,
                           toNode: self.egressNode!,
                           toPort: 0)
*/
        /*try connectWire(fromNode: ingressNode,
                        fromPort: ingressNode.dynamicOutputs.first!,
                        toNode: staticFileNode,
                        toPort: StaticFileNode.inputPort)

        try connectWire(fromNode: staticFileNode,
                        fromPort: StaticFileNode.outputPort,
                        toNode: egressNode,
                        toPort: egressNode.dynamicInputs.first!)
*/
        try ingressNode.assignValue(outputPort: ingressNode!.dynamicOutputs.first!, value: [UInt8]().intern())
        try! printAll()

        try processAllMessages()
        try! printAll()
    }

    func loadOrCreateSingletonNode<N: NodeType>(kind: UInt, name: String) throws -> N {
        if let existingNodeRaw = try database.selectNodes(kind: kind).first {
            return try wrapRawNode(nodeRaw: existingNodeRaw) as! N
        } else {
            let node = try makeNode(kind: kind, name: name)
            node.nodeContext.nodeID = try insertNode(node)
            return node as! N
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

    func wrapRawNode(nodeRaw: Node) throws -> NodeType {
        let node = try nodeFactory.makeNode(kind: nodeRaw.kind, encodedJSON: nodeRaw.configuration)

        node.nodeContext = NodeContext(world: self,
                                       nodeID: nodeRaw.id!,
                                       name: nodeRaw.name)

        return node
    }

    func makeNode(kind: UInt, name: String?) throws -> NodeType {
        let newObject = try nodeFactory.makeNode(kind: kind, encodedJSON: nil)
        newObject.nodeContext = NodeContext(world: self,
                                            nodeID: nil,
                                            name: name)
        return newObject
    }

    func loadNode(nodeID: ObjectID) throws -> NodeType {
        try wrapRawNode(nodeRaw: nodeID.loadNode(from: database))
    }

    func insertNode(_ node: NodeType) throws -> ObjectID {
        try database.insertNode(.init(kind: node.descriptor.kind,
                                      name: node.nodeContext.name,
                                      configuration: node.asJSONString()))
    }

    func updateNode(_ node: NodeType) throws {
        try database.updateNode(.init(id: node.nodeContext.nodeID,
                                      kind: node.descriptor.kind,
                                      name: node.nodeContext.name,
                                      configuration: node.asJSONString()))
    }

    func deleteNode(_ node: NodeType) throws -> Bool {
        try database.deleteNode(nodeID: node.nodeContext.nodeID!)
        // TODO: cascade deletion: and notify of wire-disconnects
    }

    func connectWire(fromNode: NodeType,
                     fromPort: NodeKindDescriptor.Port,
                     toNode: NodeType,
                     toPort: NodeKindDescriptor.Port) throws {

        try database.connectWire(fromNodeID: fromNode.nodeContext.nodeID!,
                                 fromPort: fromPort.index,
                                 toNodeID: toNode.nodeContext.nodeID!,
                                 toPort: toPort.index)
    }

    func deleteWire(fromNode: NodeType, fromPort: UInt8, toNode: NodeType, toPort: UInt8) throws -> Bool {
        try deleteWire(fromNodeID: fromNode.nodeContext.nodeID!, fromPort: fromPort, toNodeID: toNode.nodeContext.nodeID!, toPort: toPort)
    }

    func deleteWire(fromNodeID: ObjectID, fromPort: UInt8, toNodeID: ObjectID, toPort: UInt8) throws -> Bool {
        let wires = try database.selectWires(comingFromNodeID: fromNodeID,
                                             fromPort: fromPort,
                                             goingToNodeID: toNodeID,
                                             toPort: toPort)

        // There should only be 0 or 1 wires..

        guard let wire = wires.first else {
            return false
        }

        let result = try database.deleteWire(wireID: wire.id!)
        try database.insertMessage(.init(kind: .wireDisconnected, targetNodeID: toNodeID, wireID: wire.id!, dataObjectID: nil, priority: 0))

        // TODO: cascade deletion:
        // 1. if a Node has no inputs, it shall be deleted, except for Ingress and Egress Nodes, which must always exist
        // 2. if a Node has no outputs, it shall be deleted, except for Ingress and Egress Nodes, which must always exist
        // 3. If a Node is deleted, all outbound wires shall be deleted, which may in turn cause more Nodes to be deleted according to rules 1 and 2
        // 4. If a Node is deleted, all inbound wires shall be deleted, which may in turn cause more Nodes to be deleted according to rules 1 and 2

        return result
    }

    func printAll() throws {
        for node in try database.selectAllNodes() {
            let highLevelNode = try! wrapRawNode(nodeRaw: node)

            print("- \(highLevelNode.description())")

            for wire in try database.selectWires(goingToNodeID: node.id!) {
                let fromNode = try? wire.fromNodeID.loadNode(from: database)
                let toNode = try? wire.toNodeID.loadNode(from: database)

                print("    Wire (\(wire.id ?? -1)) Node \(fromNode!.description() ?? "<unknown>") port \(wire.fromPort) ----> Node \(toNode!.description() ?? "<unknown>") port \(wire.toPort)")
            }

            for wire in try database.selectWires(comingFromNodeID: node.id!) {
                let fromNode = try? wire.fromNodeID.loadNode(from: database)
                let toNode = try? wire.toNodeID.loadNode(from: database)

                print("    Wire (\(wire.id ?? -1)) Node \(fromNode!.description() ?? "<unknown>") port \(wire.fromPort) ----> Node \(toNode!.description() ?? "<unknown>") port \(wire.toPort)")
            }
        }

        print("")

        for message in try database.selectAllMessages(limit: 10000) {
            print("- \(message.description())")
        }

        print("")
        for dataObject in try database.selectAllDataObjects() {
            print("- \(dataObject.description())")
        }

        print("")
        for nodeOutputValue in try database.selectAllNodeOutputValues() {
            print("- \(nodeOutputValue.description())")
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
        let node = try wrapRawNode(nodeRaw: rawNode)
        let allRawInputMessages = try database.selectMessages(for: rawNode.id!)
        let rawMessagesGroupedByWireID: Dictionary<ObjectID, [Message]> = Dictionary(grouping: allRawInputMessages, by: { $0.wireID })

        var inputMessages = [NodeKindDescriptor.Port: [NodeInputMessage]?]()

        let wiresOnAllInputs = try database.selectWires(goingToNodeID: rawNode.id!)
        let wiresGroupedByInputPort: Dictionary<UInt8, [Wire]> = Dictionary(grouping: wiresOnAllInputs, by: { $0.toPort })

        for inputPort in node.descriptor.inputs {
            inputMessages[inputPort] = nil // default to nil, meaning no messages on this port

//        for inputIndex in 0 ..< node.descriptor.inputs.count {
            let wiresOnInputPort = wiresGroupedByInputPort[inputPort.index]!

            var inputMessagesForThisPort = [NodeInputMessage]()

            for wire in wiresOnInputPort {

                for message in rawMessagesGroupedByWireID[wire.id!] ?? [] {

                    let inputMessage: NodeInputMessage

                    var dataObject: DataObject? = nil

                    let sourceNodeOutputValue = try database.selectNodeOutputValue(nodeID: wire.fromNodeID, port: wire.fromPort)

                    if let sourceNodeOutputValue {
                        if let dataObjectID = sourceNodeOutputValue.dataObjectID {
                            dataObject = try database.selectDataObjectByID(dataObjectID)
                        }
                    }

                    switch message.kind {

                    case .wireConnected:
                        inputMessage = .init(originNodeID: message.targetNodeID,
                                             originOutputPort: wire.toPort,
                                             kind: .wireConnected(currentValue: dataObject))
                    case .wireDisconnected:
                        inputMessage = .init(originNodeID: message.targetNodeID,
                                             originOutputPort: wire.toPort,
                                             kind: .wireDisconnected)
                    case .valueMutated:
                        inputMessage = .init(originNodeID: message.targetNodeID,
                                             originOutputPort: wire.toPort,
                                             kind: .valueMutated(newValue: dataObject, oldValue: nil))
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

                inputMessages[inputPort] = inputMessagesForThisPort
            }
        }

        let outputMessages = try node.processInputs(inputMessages)

        // Send all outputs down the output wires
        try writeToAllOutputs(outputMessages, node: node)

        try deleteAllInputMessages(allRawInputMessages)
    }

    func writeToAllOutputs(_ messages: [NodeKindDescriptor.Port: NodeOutputMessage?], node: NodeType) throws {

        for (port, message) in messages {

            let wiresOnThisOutput = try database.selectWires(comingFromNodeID: node.nodeContext.nodeID!,
                                                                     fromPort: port.index)

           // let outputDescriptor = node.descriptor.outputs[outputIndex]

            if let message {
                switch message {

                case .valueMutation(let value):
                    for wire in wiresOnThisOutput {
                        try database.insertOrReplaceNodeOutputValue(.init(nodeID: node.nodeContext.nodeID!, port: port.index, dataObjectID: value?.id))

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
        }
    }

    func deleteAllInputMessages(_ inputMessages: [Message]) throws {
        for message in inputMessages {
            _ = try database.deleteMessage(messageID: message.id!) // TODO: error handling
        }
    }
}

extension NodeType {
    func description() -> String {
        "\(String(describing: Self.self)) (kind: \(descriptor.kind)), NodeID: \(nodeContext.nodeID ?? -1), name: \(nodeContext.name ?? "nil"), inputs: \(descriptor.inputs.count), outputs: \(descriptor.outputs.count)"
    }
}

extension NodeType {
    static func fromJSONString(_ string: String?) throws -> Self {
        guard let string else {
            return try .init() // default initializer gives "starting" values to all properties
        }

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
