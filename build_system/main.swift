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

// Fundamentally, the system is a kind of workflow system; every Node has its own logical local queue that can hold messages, and a message processing cycle for a Node removes all queued messages for the Node.

// In the simplest scenario, messages for the current Node are read from the database, the Node is loaded, processes the messages, updates its persistent outputs if needed, posts messages on its output Wires, in rare cases mutates its own state, which is more often more like a static configuration, the state is persisted back to the database row that represents the state of the Node.

// As an optimization, if the persistent output is unlikely to be actually used, it can be marked as lazy. This means no value is cached in the database. When another Node follows its input Wire back and wants to read the persistent output value, it will load the Node into memory and ask it to compute its output value, at which point it will also be cached, transitioning it from lazy to a regular cached value. If a cached persistent output exists on disk, then there is no need to load the Node in order to read the value. It's important to remember that a mutating output also transmits mutation messages to all subscribers, even when the value is lazy. This allows, as an example, an expensive and large list of filenames to not have to be recreated every time a file is added or removed from the list, yet add/remove mutations can still be handled by subscribers.

// The system is designed for build pipelines. As such, message-sending between Nodes is not intended to mimic method calls between Nodes. There is no way to "call" a Node and wait for its response message.

// Wires take a more pragmatic approach. As the database supports reading uncommitted changes, they are directly read and written without in-memory caching.

// A more complex scenario is when a loaded Node needs to read outputs of other Nodes before it can complete its processing. There should never be a case that we need to call other "private" methods on a Node, since all data in and out should pass through Wires, to allow caching and routing to work correctly.

// In this case those Nodes are lazily loaded as needed, but they do not get a chance to process any in-database messages pending for them. That is because, if they did, the Node would be "queue jumping" in terms of the order of message processing. Any Node may also be mutated as part of this processing. When that happens they will be persisted back to the database at the end of the current message processing cycle.

let buildEngine = try! BuildEngine()

func main() throws {
    _ = buildEngine
}

try main()

// MARK: Messages and ports

enum NodeInputMessageKind {
    case wireConnected
    case wireDisconnected
    case valueMutated(delta: DataObjectHash?)
    case error(description: String)
}

struct NodeInputMessage {
    let originNodeID: ObjectID
    let originOutputPort: UInt8
    let kind: NodeInputMessageKind
}

struct ErrorInfo {
    let nodeID: ObjectID
    let outputPort: UInt8
    let description: String
}

enum NoValueReason {
    case computingValue
    case awaitingDependency
    case lazy
    case error(stack: [ErrorInfo])
}

enum NodeOutputValue {
    case noValue(reason: NoValueReason)
    case value(DataObjectHash)
}

struct NodeProcessPortOutput {
    let value: NodeOutputValue
    // Optionally an output can transmit messages to all subscribers, used to describe differential changes to the value itself, as this can be more efficient than assembling and sending a huge chunk each time.
    let deltaMessage: DataObjectHash?
}

enum PortValueDataType: Codable, Hashable {
    case utf8Text
    case binary
    case json
    case custom(dataTypeName: String)
}

struct NodeKindDescriptor {
    enum PortKind: Codable, Hashable {
        case value(dataType: PortValueDataType)
        case eventsOnly
    }

    struct InputPort: Codable, Hashable {
        let index: UInt8
        let name: String
        let kind: PortKind
        let maximumConnections: UInt8?
        let minimumConnections: UInt8
    }

    struct OutputPort: Codable, Hashable {
        let index: UInt8
        let name: String
        let kind: PortKind
    }

    let kind: UInt
    let inputs: [InputPort]
    let outputs: [OutputPort]
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

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.OutputPort: NodeProcessPortOutput?]
}

extension NodeType {
    func assignValue(outputPort: NodeKindDescriptor.OutputPort, value: NodeOutputValue) throws {
        try nodeContext.assignValue(outputPort: outputPort.index, value: value)
    }

    func postMutationEvent(outputPort: NodeKindDescriptor.OutputPort, eventData: DataToken) throws {
        try nodeContext.postMutationEvent(outputPort: outputPort.index, dataObjectHash: eventData)
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


protocol BuildEngineType {
    var database: DatabaseLayer { get }

    func readValues(nodeID: ObjectID, inputPort: UInt8) throws -> [NodeOutputValue]
    func assignValue(nodeID: ObjectID, outputPort: UInt8, value: NodeOutputValue) throws
    func postMutationEvent(nodeID: ObjectID, outputPort: UInt8, dataObjectHash: DataObjectHash) throws
    func loadOrCreateSingletonNode<N: NodeType>(kind: UInt, name: String) throws -> N

}

struct NodeContext {
    let buildEngine: BuildEngineType
    var nodeID: ObjectID? // nil when created in memory but not yet inserted
    var name: String?

    func updateNode() {
//        try buildEngine.saveNode(nodeID: nodeID, node: self, name: name)
    }

    func readValues(inputPort: UInt8) throws -> [NodeOutputValue?] {
        try buildEngine.readValues(nodeID: nodeID!, inputPort: inputPort)
    }

    func assignValue(outputPort: UInt8, value: NodeOutputValue) throws {
        try buildEngine.assignValue(nodeID: nodeID!, outputPort: outputPort, value: value)
    }

    func postMutationEvent(outputPort: UInt8, dataObjectHash: DataObjectHash) throws {
        try buildEngine.postMutationEvent(nodeID: nodeID!, outputPort: outputPort, dataObjectHash: dataObjectHash)
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

final class BuildEngine: BuildEngineType {

    let database: DatabaseLayer
    let nodeFactory: NodeFactory

    init(database: DatabaseLayer = try! DatabaseLayer(filePath: "database34.sqlite"),
         nodeFactory: NodeFactory = NodeFactory()) throws {

        self.database = database
        self.nodeFactory = nodeFactory

        try processAllMessages()
    }

    func loadOrCreateSingletonNode<N: NodeType>(kind: UInt, name: String) throws -> N {
        if let existingNodeRaw = try database.selectNodes(kind: kind).first {
            // TODO! search by Name
            return try wrapRawNode(nodeRaw: existingNodeRaw) as! N
        } else {
            let node = try makeNode(kind: kind, name: name)
            node.nodeContext.nodeID = try saveNode(node)
            return node as! N
        }
    }

    func readValues(nodeID: ObjectID, inputPort: UInt8) throws -> [NodeOutputValue] {
        let wires = try database.selectWires(goingToNodeID: nodeID, toPort: inputPort)

        return try wires.map { wire in
            let fromNodeID = wire.fromNodeID
            let fromPort = wire.fromPort

            if let nodeOutputValue = try database.selectNodeOutputValue(nodeID: fromNodeID, port: fromPort) {
                //
                switch nodeOutputValue.kind {
                case .noValueAwaitingDependency:
                    return .noValue(reason: .awaitingDependency)
                case .noValueComputingValue:
                    return .noValue(reason: .computingValue)
                case .noValueError:
                    return .noValue(reason: .error(stack: [])) // TODO
                case .noValueLazy:
                    return .noValue(reason: .lazy)
                case .value:
                    if let dataObjectHash = nodeOutputValue.dataObjectHash {
                        return .value(try database.selectDataObject(hash: dataObjectHash)!.hash)
                    }
                }
            } else {
                // no value has been saved to disk. how to map this without guessing? maybe a node should always have a value saved no matter what?
            }

            return .noValue(reason: .computingValue)
        }
    }

    func assignValue(nodeID: ObjectID, outputPort: UInt8, value: NodeOutputValue) throws {
        let wires = try database.selectWires(comingFromNodeID: nodeID, fromPort: outputPort)

        var kind: DatabaseModels.NodeOutputValue.ValueKind = .value
        var dataObjectHash: DataObjectHash? = nil

        switch value {
        case .value(let actualValue):
            kind = .value
            dataObjectHash = actualValue

        case .noValue(let reason):
            dataObjectHash = nil

            switch reason {
            case .awaitingDependency:
                kind = .noValueAwaitingDependency
            case .computingValue:
                kind = .noValueComputingValue
            case .lazy:
                kind = .noValueLazy
            case .error(let stack):
                kind = .noValueError
            }
        }

        try database.insertOrReplaceNodeOutputValue(.init(nodeID: nodeID, port: outputPort, kind: kind, dataObjectHash: dataObjectHash))

        for wire in wires {
            // TODO: prevent more than one queued if the type is valueMutated
            try database.insertMessage(.init(kind: .valueMutated,
                                             targetNodeID: wire.toNodeID,
                                             wireID: wire.id!,
                                             dataObjectHash: nil, // TODO: this could contain a delta for the mutation.
                                             priority: 0))
        }
    }

    func postMutationEvent(nodeID: ObjectID, outputPort: UInt8, dataObjectHash: DataObjectHash) throws {
        let wires = try database.selectWires(comingFromNodeID: nodeID, fromPort: outputPort)

        for wire in wires {
            try database.insertMessage(.init(kind: .valueMutated,
                                             targetNodeID: wire.toNodeID,
                                             wireID: wire.id!,
                                             dataObjectHash: dataObjectHash,
                                             priority: 0))
        }
    }

    func wrapRawNode(nodeRaw: Node) throws -> NodeType {
        let node = try nodeFactory.makeNode(kind: nodeRaw.kind, encodedJSON: nodeRaw.configuration)
        node.nodeContext = .init(buildEngine: self, nodeID: nodeRaw.id!, name: nodeRaw.name)
        return node
    }

    func makeNode(kind: UInt, name: String?) throws -> NodeType {
        let newObject = try nodeFactory.makeNode(kind: kind, encodedJSON: nil)
        newObject.nodeContext = .init(buildEngine: self, nodeID: nil, name: name)
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
                     fromPort: NodeKindDescriptor.OutputPort,
                     toNode: NodeType,
                     toPort: NodeKindDescriptor.InputPort) throws {

        try database.connectWire(fromNodeID: fromNode.nodeContext.nodeID!,
                                 fromPort: fromPort.index,
                                 toNodeID: toNode.nodeContext.nodeID!,
                                 toPort: toPort.index)
    }

    func deleteWire(fromNode: NodeType,
                    fromPort: NodeKindDescriptor.OutputPort,
                    toNode: NodeType,
                    toPort: NodeKindDescriptor.InputPort) throws -> Bool {

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

    func processAllMessages() throws {
        while try processSomeMessages() {
        }
    }

    final class MessageProcessingCycle {
        weak var buildEngine: BuildEngine?
        var loadedNodes = [ObjectID: NodeType]()

        init(buildEngine: BuildEngine) {
            self.buildEngine = buildEngine
        }

        func processAllMessagesForOneNode(_ rawNode: Node) throws {
            let node = try buildEngine!.wrapRawNode(nodeRaw: rawNode)
            loadedNodes[rawNode.id!] = node
            // TODO: create an object that represents the current message-processing cycle for a single node, so that all state can be kept there and discarded before moving on to the next node-message group.
            try processAllMessagesForOneNode(node, nodeID: rawNode.id!)

            for (nodeID, node) in loadedNodes {
                _ = try buildEngine!.saveNode(node)
            }
        }

        private func processAllMessagesForOneNode(_ node: NodeType, nodeID: ObjectID) throws {
            let allRawInputMessages = try buildEngine!.database.selectMessages(for: nodeID)
            let rawMessagesGroupedByWireID: Dictionary<ObjectID, [Message]> = Dictionary(grouping: allRawInputMessages, by: { $0.wireID })

            var inputMessages = [NodeKindDescriptor.InputPort: [NodeInputMessage]?]()

            let wiresOnAllInputs = try buildEngine!.database.selectWires(goingToNodeID: nodeID)
            let wiresGroupedByInputPort: Dictionary<UInt8, [Wire]> = Dictionary(grouping: wiresOnAllInputs, by: { $0.toPort })

            for inputPort in node.descriptor.inputs {
                inputMessages[inputPort] = nil // default to nil, meaning no messages on this port

                let wiresOnInputPort = wiresGroupedByInputPort[inputPort.index]!

                var inputMessagesForThisPort = [NodeInputMessage]()

                for wire in wiresOnInputPort {

                    for message in rawMessagesGroupedByWireID[wire.id!] ?? [] {

                        let sourceNodeOutputValue = try buildEngine!.database.selectNodeOutputValue(nodeID: wire.fromNodeID, port: wire.fromPort)

                        var dataObject: DataObject? = nil
                        if let sourceNodeOutputValue {
                            if let dataObjectHash = sourceNodeOutputValue.dataObjectHash {
                                dataObject = try buildEngine!.database.selectDataObject(hash: dataObjectHash)
                            }
                        }

                        func kind() throws -> NodeInputMessageKind {
                            switch message.kind {
                            case .wireConnected:
                                return .wireConnected
                            case .wireDisconnected:
                                return .wireDisconnected
                            case .valueMutated:
                                return .valueMutated(delta: nil)
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
            try buildEngine!.writeToAllOutputs(outputMessages, node: node)

            try buildEngine!.deleteAllInputMessages(allRawInputMessages)
        }
    }

    private func processSomeMessages() throws -> Bool {
        let nodes = try database.selectAllNodesWithInputMessages(limit: 10)

        guard !nodes.isEmpty else {
            return false
        }

        for rawNode in nodes {
            try processAllMessagesForOneRawNode(rawNode)
        }

        return true
    }

    private func processAllMessagesForOneRawNode(_ rawNode: Node) throws {
        let transaction = try! database.beginTransaction()
        do {
            try MessageProcessingCycle(buildEngine: self).processAllMessagesForOneNode(rawNode)
            try transaction.commit()
        } catch {
            try! transaction.rollback()
            throw error
        }
    }

    // TODO: should be NodeOutputValue, not NodeOutputMessage. but then we need a way to send discrete events instead of set the values of outputs
    func writeToAllOutputs(_ messages: [NodeKindDescriptor.OutputPort: NodeProcessPortOutput?], node: NodeType) throws {

        for (port, message) in messages {

            let wiresOnThisOutput = try database.selectWires(comingFromNodeID: node.nodeContext.nodeID!,
                                                                     fromPort: port.index)

            if let message {
                var dataObjectHash: DataObjectHash?
                var kind: DatabaseModels.NodeOutputValue.ValueKind

                switch message.value
                {

                case .noValue(let reason):
                    switch reason {
                    case .awaitingDependency:
                        kind = .noValueAwaitingDependency
                    case .computingValue:
                        kind = .noValueComputingValue
                    case .error://(stack)
                        kind = .noValueError
                    case .lazy:
                        kind = .noValueLazy
                    }
                    
                    dataObjectHash = nil

                case .value(let value):
                    dataObjectHash = value
                    kind = .value
                }

                try database.insertOrReplaceNodeOutputValue(.init(nodeID: node.nodeContext.nodeID!,
                                                                  port: port.index,
                                                                  kind: kind,
                                                                  dataObjectHash: dataObjectHash))

                for wire in wiresOnThisOutput {
                    try database.insertMessage(.init(kind: .valueMutated,
                                                     targetNodeID: wire.toNodeID,
                                                     wireID: wire.id!,
                                                     dataObjectHash: message.deltaMessage,
                                                     priority: 0))
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

extension BuildEngine {
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

}



/*
 
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

 */
