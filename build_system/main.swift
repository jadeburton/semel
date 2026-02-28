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
    FileManager.default.changeCurrentDirectoryPath("/Users/jadeburton/Desktop/build_system/build_system")
    _ = buildEngine

    while let line = readLine() {
        try? buildEngine.process { processingCycle in
            try processingCycle.rootNode.commandInterpreter.handleCommand(line)
        }
    }
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
    let originOutputPortValue: NodeOutputValue
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

protocol NodeType: AnyObject, Codable, PolySerializable {

    var descriptor: NodeKindDescriptor { get }
    var nodeContext: NodeContext! { get set }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws
    func willSave() throws
    func didSave() throws
}

protocol MessageType: AnyObject, Codable, PolySerializable {
}

extension NodeType {
    func willSave() throws {
    }
    func didSave() throws {
    }
}

extension NodeType {
    func description() -> String {
        "\(String(describing: Self.self)) (kind: \(descriptor.kind)), NodeID: \(nodeContext.nodeID ?? -1), name: \(nodeContext.name ?? "nil"), inputs: \(descriptor.inputs.count), outputs: \(descriptor.outputs.count)"
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

/*
protocol BuildEngineType {
    var database: DatabaseLayer { get }

    func readValues(nodeID: ObjectID, inputPort: UInt8) throws -> [NodeOutputValue]
    func assignValue(nodeID: ObjectID, outputPort: UInt8, value: NodeOutputValue) throws
    func postMutationEvent(nodeID: ObjectID, outputPort: UInt8, dataObjectHash: DataObjectHash) throws
    func loadOrCreateSingletonNode<N: NodeType>(kind: UInt, name: String) throws -> N

}*/

struct NodeContext {
    let processingCycle: ProcessingCycle
    var nodeID: ObjectID? // nil when created in memory but not yet inserted
    var parentNodeID: ObjectID?
    var name: String?
}

extension NodeType {
    func parent<N: NodeType>() throws -> N? {
        if let parentNodeID = nodeContext.parentNodeID {
            let rawNode = try parentNodeID.loadNode(from: nodeContext.processingCycle.database)
            let node = try nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: rawNode)
            return node as? N
        } else {
            return nil
        }
    }

    func save() throws {
        try nodeContext.processingCycle.saveNode(self)
    }

    func childNode<N: NodeType>(named name: String) throws -> N? {
        if let nodeRaw = try nodeContext.processingCycle.database.selectNodes(named: name, parentNodeID: nodeContext.nodeID!).first { // TODO
            return try nodeContext.processingCycle.wrapRawNode(nodeRaw: nodeRaw)
        }
        return nil
    }

    func delete() throws {
        if let nodeID = nodeContext.nodeID {
            _ = try nodeContext.processingCycle.deleteNode(nodeID)
        }
    }

    func writeToOutputPort(_ outputPort: NodeKindDescriptor.OutputPort, value: NodeOutputValue, deltaMessage: DataObjectHash? = nil) throws {
        try nodeContext.processingCycle.writeToOutputPort(outputPort, value: value, deltaMessage: nil, nodeID: nodeContext.nodeID!)
    }

    // Returns a named child (without path support)
    func childIfExists<N: NodeType>(named name: String) throws -> N? {
        try nodeContext.processingCycle.node(named: name, parentNodeID: nodeContext.nodeID!)
    }

    func allChildren() throws -> [NodeType] {
        try nodeContext.processingCycle.database.selectNodes(parentNodeID: nodeContext.nodeID!).map {
            try nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: $0)
        }
    }

    // Creates the child if it does not exist
    func child<N: NodeType>(named name: String) throws -> N {
        if let existingChild: N = try nodeContext.processingCycle.node(named: name, parentNodeID: nodeContext.nodeID!) {
            return existingChild
        }
        let node = try nodeContext.processingCycle.makeNode(kind: N.kind, name: name, parentNodeID: nodeContext.nodeID!) as! N
        try node.save()
        return node
    }

    // Returns a child at a path (e.g. "example/src/main.swift"), this IS recursive.
    func child(path: String) -> NodeType? {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard !components.isEmpty else { return self }

        var currentNodeID = nodeContext.nodeID!

        for (index, name) in components.enumerated() {
            guard let rawNode = try? nodeContext.processingCycle.database
                    .selectNodes(named: name, parentNodeID: currentNodeID).first else {
                return nil
            }

            if index == components.count - 1 {
                // Last component — wrap and return the node
                return try? nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: rawNode)
            } else {
                // Intermediate component — step into this directory
                currentNodeID = rawNode.id!
            }
        }

        return nil
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

final class BuildEngine {
    let database: DatabaseLayer
    let polyFactory: PolyFactory

    init(database: DatabaseLayer = try! DatabaseLayer(filePath: "database40.sqlite"),
         polyFactory: PolyFactory = PolyFactory()) throws {

        self.database = database
        self.polyFactory = polyFactory

        try processAllMessages()
    }

    func processAllMessages() throws {
        while try processSomeMessages() {
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

    func process(_ work: @escaping (_ processingCycle: ProcessingCycle) throws -> ()) throws {
//        try database.doTransaction {
            let processingCycle = try ProcessingCycle(database: database, buildEngine: self)
            try work(processingCycle)
            try processingCycle.endCycle()
//        }
        try processAllMessages()
    }

    private func processAllMessagesForOneRawNode(_ rawNode: Node) throws {
        try process { processingCycle in
            try processingCycle.processAllMessagesForOneNode(rawNode)
        }
    }
}

// Created to process one Node that has queued messages. Destroyed and recreated for the next Node with queued messages. This allows all state related to the processing of one Node's messages to be kept in memory and discarded before moving on to the next Node.
final class ProcessingCycle {

    weak var buildEngine: BuildEngine!
    let database: DatabaseLayer
    var rootNode: RootNode!
    var loadedNodes = [ObjectID: NodeType]()

    init(database: DatabaseLayer, buildEngine: BuildEngine?) throws {

        self.database = database
        self.buildEngine = buildEngine

        // This is the first object that is created. It resides inside a plugin library that can be configured by the user.
        // The CommandInterpreter is responsible for interpreting the commands that are sent to the system, e.g. from a CLI or a UI, and translating them into node creations, wire connections, value assignments, etc. It is also responsible for creating and managing the "main" Node that represents the main build pipeline.
        rootNode = try rootObject()
      //  try! printAll()
    }

    func endCycle() throws {
        for (_, node) in loadedNodes {
            try node.save()
        }
    }

    private func rootObject<N: NodeType>() throws -> N {
        let name = "root"
        if let existingNodeRaw = try database.selectNodesInRoot(named: name).first {
            return try wrapRawNode(nodeRaw: existingNodeRaw)
        } else {
            let node = try makeNode(kind: N.kind, name: name, parentNodeID: nil)
            try node.save()
            return node as! N
        }
    }

    func readOutputValue(nodeID: ObjectID, outputPort: UInt8) throws -> NodeOutputValue? {
        try database.selectNodeOutputValue(nodeID: nodeID, port: outputPort)?.asNodeOutputValue()
    }

    func node<N: NodeType>(named name: String, parentNodeID: ObjectID) throws -> N? {
        if let nodeRaw = try database.selectNodes(named: name, parentNodeID: parentNodeID).first {
            return try wrapRawNode(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func readValues(nodeID: ObjectID, inputPort: UInt8) throws -> [NodeOutputValue] {
        let wires = try database.selectWires(goingToNodeID: nodeID, toPort: inputPort)

        return try wires.map { wire in
            let fromNodeID = wire.fromNodeID
            let fromPort = wire.fromPort

            if let nodeOutputValue = try database.selectNodeOutputValue(nodeID: fromNodeID, port: fromPort) {
                return nodeOutputValue.asNodeOutputValue()
            } else {
                // no value has been saved to disk. how to map this without guessing? maybe a node should always have a value saved no matter what?
            }

            return .noValue(reason: .computingValue)
        }
    }

    func wrapRawNode<N: NodeType>(nodeRaw: Node) throws -> N {
        try wrapRawNodePoly(nodeRaw: nodeRaw) as! N
    }

    func wrapRawNodePoly(nodeRaw: Node) throws -> NodeType {
        let node = try PolyFactory.makeNode(kind: nodeRaw.kind, encodedJSON: nodeRaw.configuration)
        node.nodeContext = .init(processingCycle: self, nodeID: nodeRaw.id!, parentNodeID: nodeRaw.parentNodeID, name: nodeRaw.name)
        loadedNodes[nodeRaw.id!] = node
        return node
    }

    func makeNode(kind: UInt, name: String?, parentNodeID: ObjectID?) throws -> NodeType {
        let newObject = try PolyFactory.makeNode(kind: kind, encodedJSON: nil)
        newObject.nodeContext = .init(processingCycle: self, nodeID: nil, parentNodeID: parentNodeID, name: name)
        return newObject
    }

    func saveNode(_ node: NodeType) throws {
        try node.willSave()

        if let nodeID = node.nodeContext.nodeID {
            try database.updateNode(.init(id: nodeID,
                                          parentNodeID: node.nodeContext.parentNodeID,
                                          kind: node.descriptor.kind,
                                          name: node.nodeContext.name,
                                          configuration: node.asJSONString()))
        } else {
            node.nodeContext.nodeID = try database.insertNode(.init(parentNodeID: node.nodeContext.parentNodeID,
                                                                    kind: node.descriptor.kind,
                                                                    name: node.nodeContext.name,
                                                                    configuration: node.asJSONString()))
        }

        try node.didSave()
    }

    func deleteNode(_ nodeID: ObjectID) throws -> Bool {
        try database.deleteNode(nodeID: nodeID)
        // TODO: cascade deletion: and notify of wire-disconnects
    }

    func processAllMessagesForOneNode(_ rawNode: Node) throws {
        let node = try wrapRawNodePoly(nodeRaw: rawNode)
        // TODO: create an object that represents the current message-processing cycle for a single node, so that all state can be kept there and discarded before moving on to the next node-message group.
        try processAllMessagesForOneNode(node, nodeID: rawNode.id!)
    }

    private func processAllMessagesForOneNode(_ node: NodeType, nodeID: ObjectID) throws {
        let allRawInputMessages = try database.selectMessages(for: nodeID)
        let rawMessagesGroupedByWireID: Dictionary<ObjectID, [Message]> = Dictionary(grouping: allRawInputMessages, by: { $0.wireID })

        var inputMessages = [NodeKindDescriptor.InputPort: [NodeInputMessage]?]()

        let wiresOnAllInputs = try database.selectWires(goingToNodeID: nodeID)
        let wiresGroupedByInputPort: Dictionary<UInt8, [Wire]> = Dictionary(grouping: wiresOnAllInputs, by: { $0.toPort })

        for inputPort in node.descriptor.inputs {
            inputMessages[inputPort] = nil // default to nil, meaning no messages on this port

            let wiresOnInputPort = wiresGroupedByInputPort[inputPort.index]!
            var inputMessagesForThisPort = [NodeInputMessage]()

            for wire in wiresOnInputPort {

                for message in rawMessagesGroupedByWireID[wire.id!] ?? [] {

                    let sourceNodeOutputValue = try database.selectNodeOutputValue(nodeID: wire.fromNodeID, port: wire.fromPort)

                    inputMessagesForThisPort.append(.init(originNodeID: message.targetNodeID,
                                                          originOutputPort: wire.toPort,
                                                          kind: try message.asNodeInputMessageKind(),
                                                          originOutputPortValue: sourceNodeOutputValue?.asNodeOutputValue() ?? .noValue(reason: .computingValue)))
                }

                inputMessages[inputPort] = inputMessagesForThisPort
            }
        }

        print("processInputs: node \(node) -- \(inputMessages)")

        try node.processInputs(inputMessages)

        for message in allRawInputMessages {
            _ = try database.deleteMessage(messageID: message.id!) // TODO: error handling
        }
    }

    func writeToOutputPort(_ outputPort: NodeKindDescriptor.OutputPort,
                           value: NodeOutputValue,
                           deltaMessage: DataObjectHash?,
                           nodeID: ObjectID) throws {

        let wiresOnThisOutput = try database.selectWires(comingFromNodeID: nodeID,
                                                                 fromPort: outputPort.index)

        let (dataObjectHash, kind) = try value.mapNodeOutputValue()

        try database.insertOrReplaceNodeOutputValue(.init(nodeID: nodeID,
                                                          port: outputPort.index,
                                                          kind: kind,
                                                          dataObjectHash: dataObjectHash))

        for wire in wiresOnThisOutput {
            try database.insertMessage(.init(kind: .valueMutated,
                                             targetNodeID: wire.toNodeID,
                                             wireID: wire.id!,
                                             dataObjectHash: deltaMessage,
                                             priority: 0))
        }
    }
}

// Wire management
extension ProcessingCycle {
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
}

extension Message {
    func asNodeInputMessageKind() throws -> NodeInputMessageKind {
        switch kind {
        case .wireConnected:
            return .wireConnected
        case .wireDisconnected:
            return .wireDisconnected
        case .valueMutated:
            return .valueMutated(delta: dataObjectHash)
        case .error:
            return .error(description: "TODO")
        }
    }
}

extension DatabaseModels.NodeOutputValue {
    func asNodeOutputValue() -> NodeOutputValue {
        .init(nodeOutputValue: self)
    }
}

extension NodeOutputValue {
    init(nodeOutputValue: DatabaseModels.NodeOutputValue) {
        switch nodeOutputValue.kind {
        case .noValueAwaitingDependency:
            self = .noValue(reason: .awaitingDependency)
        case .noValueComputingValue:
            self = .noValue(reason: .computingValue)
        case .noValueError:
            self = .noValue(reason: .error(stack: [])) // TODO
        case .noValueLazy:
            self = .noValue(reason: .lazy)
        case .value:
            if let dataObjectHash = nodeOutputValue.dataObjectHash {
                self = .value(dataObjectHash)
            } else {
                self = .noValue(reason: .computingValue) // TODO
            }
        }
    }

    func mapNodeOutputValue() throws -> (DataObjectHash?, DatabaseModels.NodeOutputValue.ValueKind) {
        switch self
        {
        case .noValue(let reason):
            switch reason {
            case .awaitingDependency:
                return (nil, .noValueAwaitingDependency)
            case .computingValue:
                return (nil, .noValueComputingValue)
            case .error://(stack) TODO
                return (nil, .noValueError)
            case .lazy:
                return (nil, .noValueLazy)
            }

        case .value(let value):
            return (value, .value)
        }
    }
}

extension ProcessingCycle {
    func printAll() throws {
        for node in try database.selectAllNodes() {
            let highLevelNode = try! wrapRawNodePoly(nodeRaw: node)

            print("- \(highLevelNode.description())")

            for wire in try database.selectWires(goingToNodeID: node.id!) {
                let fromNode = try? wire.fromNodeID.loadNode(from: database)
                let toNode = try? wire.toNodeID.loadNode(from: database)

                print("    Wire (\(wire.id ?? -1)) Node \(fromNode!.description()) port \(wire.fromPort) ----> Node \(toNode!.description()) port \(wire.toPort)")
            }

            for wire in try database.selectWires(comingFromNodeID: node.id!) {
                let fromNode = try? wire.fromNodeID.loadNode(from: database)
                let toNode = try? wire.toNodeID.loadNode(from: database)

                print("    Wire (\(wire.id ?? -1)) Node \(fromNode!.description()) port \(wire.fromPort) ----> Node \(toNode!.description()) port \(wire.toPort)")
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
