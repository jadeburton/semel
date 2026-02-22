//
//  main.swift
//  build_system
//
//  Created by Jade Burton on 16.01.26.
//

import Foundation
import GRDB
import DatabaseModels

// Nodes are lazily loaded from the Database. When a Node exists in memory, it is a "live" Node, meaning that it can have internal state that is not yet reflected in the Database, and it can react to direct calls from other live Nodes.

// Fundamentally, the system is a kind of workflow system; messages are read from a queue in the database and processed one at a time. In the simplest scenario, a message is read from the database, the corresponding target Node is found, loaded, asked to process the message, lets its state mutate, and then the state is persisted back to the database row that represents the state of the Node.

// Wires take a more pragmatic approach. As the database supports reading uncommitted changes, they are directly read and written without in-memory caching.

// A more complex scenario is when a loaded Node needs to interrogate other Nodes before it can complete its processing. In this case those Nodes are lazily loaded as needed, but they do not get a chance to process any in-database messages pending for them. Any Node may also be mutated as part of this processing. When that happens they will be persisted back to the database at the end of the current message processing cycle.

let buildEngine = try! BuildEngine()

func main() throws {
    _ = buildEngine
}

try main()

// MARK: Messages and ports

enum NodeInputMessageKind {
    case wireConnected(currentValue: DataObject?)
    case wireDisconnected
    case valueMutated(delta: DataObject?)
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

// MARK: Data objects

typealias DataToken = DataObjectHash

extension [UInt8] {
    func intern() -> DataToken {
        let hash = Sha256.hash(self)
        if let _ = try! DatabaseLayer.shared.selectDataObject(hash: hash) {
            return hash
        } else {
            try! DatabaseLayer.shared.insertDataObject(DataObject(hash: hash, content: self))
            return hash
        }
    }
}

extension DataToken {
    func resolve() -> [UInt8]? {
        (try? DatabaseLayer.shared.selectDataObject(hash: self))?.content
    }
}

// MARK: Nodes

protocol NodeType: AnyObject, Codable {

    init() throws

    var descriptor: NodeKindDescriptor { get }
    var nodeContext: NodeContext! { get set }

    func processInputs(_ inputs: [NodeKindDescriptor.Port: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.Port: NodeOutputMessage?]
}

extension NodeType {
    func assignValue(outputPort: NodeKindDescriptor.Port, value: DataToken?) throws {
        try nodeContext.assignValue(outputPort: outputPort.index, dataObjectHash: value)
    }

    func postEvent(outputPort: NodeKindDescriptor.Port, eventData: DataToken?) throws {
        try nodeContext.postEvent(outputPort: outputPort.index, dataObjectHash: eventData)
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

extension ObjectID {
    func loadNode(from database: DatabaseLayer) throws -> Node {
        guard let node = try database.selectNodeByID(self) else {
            throw DatabaseLayer.DatabaseError.nodeNotFound
        }
        return node
    }
}


protocol World {
    var database: DatabaseLayer { get }

    func readValues(nodeID: ObjectID, inputPort: UInt8) throws -> [DataObject?]
    func assignValue(nodeID: ObjectID, outputPort: UInt8, dataObjectHash: DataObjectHash?) throws
    func postEvent(nodeID: ObjectID, outputPort: UInt8, dataObjectHash: DataObjectHash?) throws

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

    func assignValue(outputPort: UInt8, dataObjectHash: DataObjectHash?) throws {
        try world.assignValue(nodeID: nodeID!, outputPort: outputPort, dataObjectHash: dataObjectHash)
    }

    func postEvent(outputPort: UInt8, dataObjectHash: DataObjectHash?) throws {
        try world.postEvent(nodeID: nodeID!, outputPort: outputPort, dataObjectHash: dataObjectHash)
    }
}






extension DatabaseLayer {
    fileprivate func connectWire(fromNodeID: ObjectID, fromPort: UInt8, toNodeID: ObjectID, toPort: UInt8) throws {
        guard try selectWires(comingFromNodeID: fromNodeID,
                                       fromPort: fromPort,
                                       goingToNodeID: toNodeID,
                                       toPort: toPort).isEmpty else {
            return
        }

        // TODO: transactional
        // TODO: if there is a circular reference, block the creation of the Wire
        let wireID = try insertWire(.init(fromNodeID: fromNodeID, fromPort: fromPort, toNodeID: toNodeID, toPort: toPort))
        try insertMessage(.init(kind: .wireConnected, targetNodeID: toNodeID, wireID: wireID, dataObjectHash: nil, priority: 0))
    }
}

final class BuildEngine: World {
    let database: DatabaseLayer
    let nodeFactory: NodeFactory

    init(database: DatabaseLayer = try! DatabaseLayer(filePath: "database34.sqlite"),
         nodeFactory: NodeFactory = NodeFactory()) throws {

        self.database = database
        self.nodeFactory = nodeFactory

//        self.productNode = nil
//
//        ingressNode = try loadOrCreateSingletonNode(kind: CommandInterpreter.kind, name: "Ingress")
//        productNode = try loadOrCreateSingletonNode(kind: Product.kind, name: "Egress")
/*
        try connectWire(fromNode: self.ingressNode!,
                        fromPort: 0,
                        toNode: self.productNode!,
                        toPort: 0)
*/
//        let staticFileNode = try makeNode(kind: StaticFileNode.kind, name: "StaticFile") as! StaticFileNode
//        staticFileNode.nodeContext.nodeID = try insertNode(staticFileNode)
/*
        _ = try deleteWire(fromNode: self.ingressNode!,
                           fromPort: 0,
                           toNode: self.productNode!,
                           toPort: 0)
*/
 /*       try connectWire(fromNode: ingressNode,
                        fromPort: ingressNode.dynamicOutputs.first!,
                        toNode: staticFileNode,
                        toPort: StaticFileNode.inputPort)

        try connectWire(fromNode: staticFileNode,
                        fromPort: StaticFileNode.outputPort,
                        toNode: productNode,
                        toPort: productNode.dynamicInputs.first!)
*/

//        try ingressNode.assignValue(outputPort: ingressNode!.dynamicOutputs.first!, value: [UInt8]().intern())
//        try! printAll()
//
//        try processAllMessages()
//        try! printAll()
    }

    func loadOrCreateSingletonNode<N: NodeType>(kind: UInt, name: String) throws -> N {
        if let existingNodeRaw = try database.selectNodes(kind: kind).first {
            return try wrapRawNode(nodeRaw: existingNodeRaw) as! N
        } else {
            let node = try makeNode(kind: kind, name: name)
            node.nodeContext.nodeID = try saveNode(node)
            return node as! N
        }
    }

    func readValues(nodeID: ObjectID, inputPort: UInt8) throws -> [DataObject?] {
        let wires = try database.selectWires(goingToNodeID: nodeID, toPort: inputPort)

        return try wires.map { wire in
            let fromNodeID = wire.fromNodeID
            let fromPort = wire.fromPort

            // TODO: this could ask the Node to provide the value for this port, instead of directly reading from the database. This way, if the Node has some internal state that is not yet reflected in the database, it can still provide the correct value. This also allows for more complex Nodes that compute their output values on demand, instead of always writing them to the database.
            let nodeOutputValue = try database.selectNodeOutputValue(nodeID: fromNodeID, port: fromPort)

            if let dataObjectHash = nodeOutputValue?.dataObjectHash {
                return try database.selectDataObject(hash: dataObjectHash)
            }

            return nil
        }
    }

    func assignValue(nodeID: ObjectID, outputPort: UInt8, dataObjectHash: DataObjectHash?) throws {
        let wires = try database.selectWires(comingFromNodeID: nodeID, fromPort: outputPort)

        try database.insertOrReplaceNodeOutputValue(.init(nodeID: nodeID, port: outputPort, dataObjectHash: dataObjectHash))

        for wire in wires {
            // TODO: prevent more than one queued if the type is valueMutated
            try database.insertMessage(.init(kind: .valueMutated,
                                             targetNodeID: wire.toNodeID,
                                             wireID: wire.id!,
                                             dataObjectHash: nil, // TODO: this could contain a delta for the mutation.
                                             priority: 0))
        }
    }

    func postEvent(nodeID: ObjectID, outputPort: UInt8, dataObjectHash: DataObjectHash?) throws {
        let wires = try database.selectWires(comingFromNodeID: nodeID, fromPort: outputPort)

        for wire in wires {
            try database.insertMessage(.init(kind: .event,
                                             targetNodeID: wire.toNodeID,
                                             wireID: wire.id!,
                                             dataObjectHash: dataObjectHash,
                                             priority: 0))
        }
    }

    func wrapRawNode(nodeRaw: Node) throws -> NodeType {
        let node = try nodeFactory.makeNode(kind: nodeRaw.kind, encodedJSON: nodeRaw.configuration)
        node.nodeContext = .init(world: self, nodeID: nodeRaw.id!, name: nodeRaw.name)
        return node
    }

    func makeNode(kind: UInt, name: String?) throws -> NodeType {
        let newObject = try nodeFactory.makeNode(kind: kind, encodedJSON: nil)
        newObject.nodeContext = .init(world: self, nodeID: nil, name: name)
        return newObject
    }

    func saveNode(_ node: NodeType) throws -> ObjectID {
        if let nodeID = node.nodeContext.nodeID {
            try database.updateNode(.init(id: nodeID,
                                          kind: node.descriptor.kind,
                                          name: node.nodeContext.name,
                                          configuration: node.asJSONString()))
            return nodeID
        } else {
            return try database.insertNode(.init(kind: node.descriptor.kind,
                                                 name: node.nodeContext.name,
                                                 configuration: node.asJSONString()))
        }
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

    func deleteWire(fromNode: NodeType,
                    fromPort: NodeKindDescriptor.Port,
                    toNode: NodeType,
                    toPort: NodeKindDescriptor.Port) throws -> Bool {

        try deleteWire(fromNodeID: fromNode.nodeContext.nodeID!,
                       fromPort: fromPort.index,
                       toNodeID: toNode.nodeContext.nodeID!,
                       toPort: toPort.index)
    }

    func deleteNodeAndConnectingWires(nodeID: ObjectID) {
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
        try database.insertMessage(.init(kind: .wireDisconnected, targetNodeID: toNodeID, wireID: wire.id!, dataObjectHash: nil, priority: 0))

        // TODO: cascade deletion:
        // - After deleting the Wire, check the origin Node. If it has no output wires at all, delete it and follow all wires going TO the origin Node. These wires should be deleted using this deleteWire method, e.g. recursive.

        let numberOfInboundWiresToOrigin = try database.selectWires(goingToNodeID: fromNodeID).count
        let numberOfOutboundWiresFromOrigin = try database.selectWires(comingFromNodeID: fromNodeID).count

        if numberOfInboundWiresToOrigin == 0 || numberOfOutboundWiresFromOrigin == 0 {
            // Delete origin node if it is not Egress/Ingress
            deleteNodeAndConnectingWires(nodeID: fromNodeID)
        }

        let numberOfInboundWiresToTarget = try database.selectWires(goingToNodeID: toNodeID).count
        let numberOfOutboundWiresFromTarget = try database.selectWires(comingFromNodeID: toNodeID).count

        if numberOfInboundWiresToTarget == 0 || numberOfOutboundWiresFromTarget == 0 {
            // Delete target node if it is not Egress/Ingress
            deleteNodeAndConnectingWires(nodeID: toNodeID)
        }


        // - Do the same for the target Node. Also follow the wires going TO the target Node.
        // -
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

            let wiresOnInputPort = wiresGroupedByInputPort[inputPort.index]!

            var inputMessagesForThisPort = [NodeInputMessage]()

            for wire in wiresOnInputPort {

                for message in rawMessagesGroupedByWireID[wire.id!] ?? [] {

                    let sourceNodeOutputValue = try database.selectNodeOutputValue(nodeID: wire.fromNodeID, port: wire.fromPort)

                    var dataObject: DataObject? = nil
                    if let sourceNodeOutputValue {
                        if let dataObjectHash = sourceNodeOutputValue.dataObjectHash {
                            dataObject = try database.selectDataObject(hash: dataObjectHash)
                        }
                    }

                    func kind() throws -> NodeInputMessageKind {
                        switch message.kind {
                        case .wireConnected:
                            return .wireConnected(currentValue: dataObject)
                        case .wireDisconnected:
                            return .wireDisconnected
                        case .valueMutated:
                            return .valueMutated(delta: nil)
                        case .event:
                            return .event(dataObject: try database.selectDataObject(hash: message.dataObjectHash!)!)
                        case .error:
                            return .error(description: "TODO")
                        }
                    }

                    inputMessagesForThisPort.append(.init(originNodeID: message.targetNodeID,
                                                          originOutputPort: wire.toPort,
                                                          kind: try kind()))
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

            if let message {
                switch message {

                case .valueMutation(let value):
                    for wire in wiresOnThisOutput {
                        try database.insertOrReplaceNodeOutputValue(.init(nodeID: node.nodeContext.nodeID!, port: port.index, dataObjectHash: value?.hash))

                        try database.insertMessage(.init(kind: .valueMutated,
                                                         targetNodeID: wire.toNodeID,
                                                         wireID: wire.id!,
                                                         dataObjectHash: nil,
                                                         priority: 0))
                    }

                case .event(let dataObject):
                    for wire in wiresOnThisOutput {
                        try database.insertMessage(.init(kind: .event,
                                                         targetNodeID: wire.toNodeID,
                                                         wireID: wire.id!,
                                                         dataObjectHash: dataObject.hash,
                                                         priority: 0))
                    }

                case .error(let description):
                    for wire in wiresOnThisOutput {
                        try database.insertMessage(.init(kind: .error,
                                                         targetNodeID: wire.toNodeID,
                                                         wireID: wire.id!,
                                                         dataObjectHash: nil,
                                                         priority: 0))
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

//extension Database {
//    func removeAllWiresBetweenNodes(firstNodeID: ObjectID, secondNodeID: ObjectID) throws {
//    }
//}
