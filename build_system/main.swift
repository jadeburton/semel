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
    FileManager.default.changeCurrentDirectoryPath("/Users/jadeburton/Desktop/C1/C1")
    _ = buildEngine

    while let line = readLine() {
        try? buildEngine.process { processingCycle in
            try processingCycle.rootNode.commandInterpreter.handleCommand(line)
        }
    }
}

try main()

// MARK: Messages and ports

//enum NodeMessageKind {
//    case valueMutated(delta: DataObjectHash?)
//    case error(description: String)
//}

struct ErrorInfo {
    let nodeID: ObjectID
    let outputPort: UInt8
    let description: String
}

enum NoValueReason {
    case pending
//    case nodeInitializing
//    case awaitingDependency
//    case lazy
    case error(message: String)
}

enum NodeValueKind {
    case noValue(reason: NoValueReason)
    case value(dataObjectHash: DataObjectHash, metadata: (any PolySerializable)?)
}

struct NodeMessage {
    let originNodeID: ObjectID
    let originOutputPort: UInt8
    let dataObjectHash: DataObjectHash
//    let kind: NodeMessageKind
//    let originOutputPortValue: NodeValue
}

struct NodeValue {
    let originNodeID: ObjectID
    let originOutputPort: UInt8
    let kind: NodeValueKind
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
        case messageStream(dataType: PortValueDataType)
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

extension NodeKindDescriptor {

    func outputPort(named name: String) -> NodeKindDescriptor.OutputPort? {
        return outputs.first(where: { $0.name == name })
    }

    func inputPort(named name: String) -> NodeKindDescriptor.InputPort? {
        return inputs.first(where: { $0.name == name })
    }
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

extension String {
    func intern() -> DataToken {
        [UInt8](data(using: .utf8)!).intern()
    }
}

enum DataObjectError: Error {
    case dataObjectNotFoundByHash
}

extension DataToken {
    func resolve() throws -> [UInt8] {
        guard let dataObject = try DatabaseLayer.shared.selectDataObject(hash: self) else {
            throw DataObjectError.dataObjectNotFoundByHash
        }

        return dataObject.content
    }

    func resolveAsString() throws -> String {
        String(decoding: try resolve(), as: Unicode.UTF8.self)
    }
}

// MARK: Nodes

protocol NodeType: AnyObject, Codable, PolySerializable, WithDefaultInitializer {

    var descriptor: NodeKindDescriptor { get }
    var nodeContext: NodeContext! { get set }

    // Updates all output values based on the current input values, and also
    // processes and removes all messages that are queued on any message-stream input ports.
    func process() throws

    func willSave() throws
    func didSave() throws
}

protocol WithDefaultInitializer {
    init() throws
}

// NodeType
extension PolyFactory {
    /// Construct a default instance of the type identified by `kind`.
    static func makeDefault(kind: UInt) throws -> NodeType {
        try (type(kind: kind) as! (PolySerializable & WithDefaultInitializer).Type).init() as! NodeType
    }

    /// Convenience: decode from JSON if available, otherwise create a default instance.
//    static func make(kind: UInt, encodedJSON: String) throws -> any NodeType {
//        try decode(encodedJSON: encodedJSON) as! NodeType
//    }
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

struct NodeContext {
    let processingCycle: ProcessingCycle
    var nodeID: ObjectID? // nil when created in memory but not yet inserted
    var parentNodeID: ObjectID?
    var name: String? {
        didSet {
            assert(name == nil || name!.contains("/") == false)
        }
    }
}

extension NodeType {
    func parent<N: NodeType>() throws -> N? {
        try nodeContext.processingCycle.parentNode(node: self)
    }

    func save() throws {
        try nodeContext.processingCycle.saveNode(self)
    }

    func buildFullPathName(rootName: String = "root") throws -> String {
        let name = nodeContext.name ?? "<no name>"

        guard let parentNode = try nodeContext.processingCycle.parentNodePoly(node: self) else {
            return name
        }

        if parentNode.nodeContext.name == rootName {
            return ""
        }

        let parentPath = try parentNode.buildFullPathName()

        return parentPath.isEmpty ? name : (parentPath + "/" + name)
    }

    func child(named name: String) throws -> (any NodeType)? {
        try nodeContext.processingCycle.nodePoly(named: name, parentNodeID: nodeContext.nodeID!)
    }

    func delete() throws {
        if let nodeID = nodeContext.nodeID {
            _ = try nodeContext.processingCycle.deleteNode(nodeID)
        }
    }

    func removeAllMessagesFromInputPorts() throws -> [NodeKindDescriptor.InputPort: [NodeMessage]] {
        try nodeContext.processingCycle.removeAllMessagesFromInputPorts(node: self)
    }

    func readAllValuesFromInputPort(_ inputPort: NodeKindDescriptor.InputPort) throws -> [NodeValue] {
        try nodeContext.processingCycle.readFromInputPort(inputPort, nodeID: nodeContext.nodeID!)
    }

    // Returning nil means there is nothing yet connected to the input port (i.e. not that the value is not set)
    func readOneValueFromInputPort(_ inputPort: NodeKindDescriptor.InputPort) throws -> NodeValue? {
        let values = try readAllValuesFromInputPort(inputPort)

        switch values.count {
        case 0:
            return nil
        case 1:
            return values.first!
        default:
            throw NodeError.onlyOneWireShouldBeConnectedToInput
        }
    }

    func readFromOutputPort(_ outputPort: NodeKindDescriptor.OutputPort) throws -> NodeValue {
        try nodeContext.processingCycle.readFromOutputPort(outputPort, nodeID: nodeContext.nodeID!)
    }

    func writeToOutputPort(_ outputPort: NodeKindDescriptor.OutputPort, value: NodeValueKind) throws {
        try nodeContext.processingCycle.writeToOutputPort(outputPort, value: value, nodeID: nodeContext.nodeID!)
    }

    func postMessageToOutputPort(_ outputPort: NodeKindDescriptor.OutputPort, message: MessageType) throws {
        try nodeContext.processingCycle.postMessageToOutputPort(outputPort, message: message, nodeID: nodeContext.nodeID!)
    }

    // Returns a named child (without path support)
    //    func childIfExists<N: NodeType>(named name: String) throws -> N? {
    //        try nodeContext.processingCycle.node(named: name, parentNodeID: nodeContext.nodeID!)
    //    }
    
    func allChildren() throws -> [NodeType] {
        try nodeContext.processingCycle.allChildNodes(nodeID: nodeContext.nodeID!)
    }
    
    func childPoly(named name: String, kind: UInt, createIfNotExist: Bool = false) throws -> NodeType? {
        if let existingChild = try nodeContext.processingCycle.nodePoly(named: name, parentNodeID: nodeContext.nodeID!) {
            return existingChild
        }
        if !createIfNotExist {
            return nil
        }
        return try nodeContext.processingCycle.makeNodePoly(kind: kind, name: name, parentNodeID: nodeContext.nodeID!)
    }
    
    // Creates the child if it does not exist
    func child<N: NodeType>(named name: String, createIfNotExist: Bool = false) throws -> N? {
        if let existingChild: N = try nodeContext.processingCycle.node(named: name, parentNodeID: nodeContext.nodeID!) {
            return existingChild
        }
        if !createIfNotExist {
            return nil
        }
        return try nodeContext.processingCycle.makeNodePoly(kind: N.kind, name: name, parentNodeID: nodeContext.nodeID!) as! N?
    }
    
    // Returns a child at a path (e.g. "example/src/main.swift"), this IS recursive.
    func child<N: NodeType>(path: String, createIfNotExist: Bool = false) throws -> N? {
        try nodeContext.processingCycle.childNode(path: path,
                                                  rootNodeID: nodeContext.nodeID!,
                                                  createIfNotExist: createIfNotExist)
    }

    // Returns a child at a path (e.g. "example/src/main.swift"), this IS recursive.
    func childPoly(path: String, kind: UInt, createIfNotExist: Bool = false) throws -> NodeType? { // TODO: get rid of these optionals
        try nodeContext.processingCycle.childNodePoly(path: path,
                                                      rootNodeID: nodeContext.nodeID!,
                                                      kind: kind,
                                                      createIfNotExist: createIfNotExist)
    }
}

extension PolySerializable {
    func asDataObjectHash() throws -> DataObjectHash {
        (try toJSON()).intern()
    }
}

final class BuildEngine {
    let database: DatabaseLayer

    init(database: DatabaseLayer = try! DatabaseLayer(filePath: "database74.sqlite")) throws {
        try DefaultTools.setup(toolExecutorRegistry: .instance)

        self.database = database

        _ = try processSomeNodes()
    }

    private func processSomeNodes() throws -> Bool {
        let rawNodes = try database.selectAllScheduledNodes(limit: 10)

        guard !rawNodes.isEmpty else {
            return false
        }

        for rawNode in rawNodes {
            try processAllForOneRawNode(rawNode)
        }

        return true
    }

    func process(_ work: @escaping (_ processingCycle: ProcessingCycle) throws -> ()) throws {
//        try database.doTransaction {
            let processingCycle = try ProcessingCycle(database: database, buildEngine: self)
            try work(processingCycle)
            try processingCycle.endCycle()
//        }
        _ = try processSomeNodes()
    }

    private func processAllForOneRawNode(_ rawNode: Node) throws {
        try process { processingCycle in
            try processingCycle.processOneNode(rawNode)
        }
    }
}

// Created to process one Node that has queued messages. Destroyed and recreated for the next Node with queued messages. This allows all state related to the processing of one Node's messages to be kept in memory and discarded before moving on to the next Node.
final class ProcessingCycle {

    weak var buildEngine: BuildEngine!
    let database: DatabaseLayer
    var rootNode: RootNode!
    private var loadedNodes = [ObjectID: NodeType]()

    init(database: DatabaseLayer, buildEngine: BuildEngine?) throws {

        self.database = database
        self.buildEngine = buildEngine

        // This is the first object that is created. It resides inside a plugin library that can be configured by the user.
        // The CommandInterpreter is responsible for interpreting the commands that are sent to the system, e.g. from a CLI or a UI, and translating them into node creations, wire connections, value assignments, etc. It is also responsible for creating and managing the "main" Node that represents the main build pipeline.
        rootNode = try rootObject()
        try! printAll()
        //try rootNode.buildGraph.debugPrintTree()
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
            return try makeNode(name: name, parentNodeID: nil)
        }
    }
}

// Node management
extension ProcessingCycle {
    func allChildNodes(nodeID: ObjectID) throws -> [NodeType] {
        try database.selectNodes(parentNodeID: nodeID).map {
            try wrapRawNodePoly(nodeRaw: $0)
        }
    }

    func parentNode<N: NodeType>(node: NodeType) throws -> N? {
        if let parentNodeID = node.nodeContext.parentNodeID {
            let rawNode = try parentNodeID.loadNode(from: node.nodeContext.processingCycle.database)
            let node = try node.nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: rawNode)
            return node as? N
        } else {
            return nil
        }
    }

    func parentNodePoly(node: NodeType) throws -> NodeType? {
        if let parentNodeID = node.nodeContext.parentNodeID {
            let rawNode = try parentNodeID.loadNode(from: node.nodeContext.processingCycle.database)
            let node = try node.nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: rawNode)
            return node
        } else {
            return nil
        }
    }

    func node<N: NodeType>(nodeID: ObjectID) throws -> N {
        if let nodeRaw = try database.selectNodeByID(nodeID) {
            return try wrapRawNode(nodeRaw: nodeRaw)
        } else {
            throw NodeError.nodeNotFound
        }
    }

    func nodePoly(nodeID: ObjectID) throws -> NodeType? {
        if let nodeRaw = try database.selectNodeByID(nodeID) {
            return try wrapRawNodePoly(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func nodePoly(named name: String, parentNodeID: ObjectID) throws -> NodeType? {
        if let nodeRaw = try database.selectNodes(named: name, parentNodeID: parentNodeID).first {
            return try wrapRawNodePoly(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func node<N: NodeType>(named name: String, parentNodeID: ObjectID) throws -> N? {
        if let nodeRaw = try database.selectNodes(named: name, parentNodeID: parentNodeID).first {
            return try wrapRawNode(nodeRaw: nodeRaw)
        } else {
            return nil
        }
    }

    func childNode<N: NodeType>(path: String, rootNodeID: ObjectID, createIfNotExist: Bool = false) throws -> N? {
        try childNodePoly(path: path, rootNodeID: rootNodeID, kind: N.kind, createIfNotExist: createIfNotExist)! as? N
    }

    func childNodePoly(path: String, rootNodeID: ObjectID, kind: UInt, createIfNotExist: Bool = false) throws -> NodeType? {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var currentNodeID = rootNodeID

        for (index, name) in components.enumerated() {
            guard let rawNode = try? database.selectNodes(named: name, parentNodeID: currentNodeID).first else {
                if !createIfNotExist {
                    return nil
                }
                return try makeNodePoly(kind: kind, name: name, parentNodeID: currentNodeID)
            }

            if index == components.count - 1 {
                // Last component — wrap and return the node
                return try? wrapRawNodePoly(nodeRaw: rawNode)
            } else {
                // Intermediate component — step into this directory
                currentNodeID = rawNode.id!
            }
        }

        return try wrapRawNodePoly(nodeRaw: rootNodeID.loadNode(from: database))
    }

    func wrapRawNode<N: NodeType>(nodeRaw: Node) throws -> N {
        try wrapRawNodePoly(nodeRaw: nodeRaw) as! N
    }

    func wrapRawNodePoly(nodeRaw: Node) throws -> NodeType {
        let node = try PolyFactory.decode(encodedJSON: nodeRaw.configuration!) as! NodeType
        node.nodeContext = .init(processingCycle: self, nodeID: nodeRaw.id!, parentNodeID: nodeRaw.parentNodeID, name: nodeRaw.name)
        loadedNodes[nodeRaw.id!] = node
        return node
    }

    func makeNode<N: NodeType>(name: String?, parentNodeID: ObjectID?) throws -> N {
        try makeNodePoly(kind: N.kind, name: name, parentNodeID: parentNodeID) as! N
    }

    func makeNodePoly(kind: UInt, name: String?, parentNodeID: ObjectID?) throws -> NodeType {
        let newObject = try PolyFactory.makeDefault(kind: kind)
        newObject.nodeContext = .init(processingCycle: self, nodeID: nil, parentNodeID: parentNodeID, name: name)

        // To simplify things, even when a Node is created in memory it is also created on disk. We can always rollback.
        try saveNode(newObject)
        loadedNodes[newObject.nodeContext.nodeID!] = newObject

        // Create all NodeOutputValues for the Node, as these should always exist for all non-stream output ports
        try writePendingToAllOutputsOfNode(nodeID: newObject.nodeContext.nodeID!)
        return newObject
    }

    func scheduleNode(_ nodeID: ObjectID) throws {
        var existing = try database.selectNodeByID(nodeID)!
        existing.scheduled = true
        try database.updateNode(existing)
    }

    func saveNode(_ node: NodeType, scheduled: Bool? = nil) throws {
        try node.willSave()

        if let nodeID = node.nodeContext.nodeID {
            let existing = try database.selectNodeByID(nodeID)!
            try database.updateNode(.init(id: nodeID,
                                          parentNodeID: node.nodeContext.parentNodeID,
                                          kind: node.descriptor.kind,
                                          name: node.nodeContext.name,
                                          configuration: node.toJSON(),
                                          scheduled: scheduled == nil ? existing.scheduled : scheduled!))
        } else {
            node.nodeContext.nodeID = try database.insertNode(.init(parentNodeID: node.nodeContext.parentNodeID,
                                                                    kind: node.descriptor.kind,
                                                                    name: node.nodeContext.name,
                                                                    configuration: node.toJSON(),
                                                                    scheduled: scheduled ?? false))
        }

        try node.didSave()
    }

    func deleteNode(_ nodeID: ObjectID) throws -> Bool {
        try database.deleteNode(nodeID: nodeID)
        // TODO: cascade deletion: and notify of wire-disconnects
    }
}

extension NodeType {
    func findNodeConnectedToNodeViaInputWire(named name: String, fromPort: String) throws -> (any NodeType)? {
        try nodeContext.processingCycle.findNodeConnectedToNodeViaInputWire(self, named: name, fromPort: fromPort)
    }
}

enum NodeError: Error {
    case nodeNotFound
    case onlyOneWireShouldBeConnectedToInput
}

extension ProcessingCycle {
    func processOneNode(_ rawNode: Node) throws {
        let node = try wrapRawNodePoly(nodeRaw: rawNode)
        // TODO: create an object that represents the current message-processing cycle for a single node, so that all state can be kept there and discarded before moving on to the next node-message group.
        //        try processOneNode(node, nodeID: rawNode.id!)
        print("process: node \(type(of: node)), nodeID \(rawNode.id!)")
        try node.process()
        try saveNode(node, scheduled: false)

        validateNodeOutputValues(node: node)
        validateMessagesWereProcessed(node: node)
    }

    private func validateNodeOutputValues(node: NodeType) {
        assert(try! database.selectAllNodeOutputValues(nodeID: node.nodeContext.nodeID!).filter { $0.kind == .pending }.isEmpty, "Not all NodeOutputValues were processed for node \(node.description())")
    }

    private func validateMessagesWereProcessed(node: NodeType) {
        assert(try! database.selectMessages(for: node.nodeContext.nodeID!).isEmpty, "Not all messages were processed for node \(node.description())")
    }
}

enum ProcessingCycleError: Error {
    case outputPortHasNoValue
}

// Port management
extension ProcessingCycle {
    func readFromOutputPort(_ outputPort: NodeKindDescriptor.OutputPort, nodeID: ObjectID) throws -> NodeValue {
        guard let nodeOutputValue = try database.selectNodeOutputValue(nodeID: nodeID, port: outputPort.index) else {
            throw ProcessingCycleError.outputPortHasNoValue
        }

        return try nodeOutputValue.asNodeOutputValue()
    }

    func removeAllMessagesFromInputPorts(node: NodeType) throws -> [NodeKindDescriptor.InputPort: [NodeMessage]] {

        let allRawInputMessages = try database.selectMessages(for: node.nodeContext.nodeID!)
        let rawMessagesGroupedByWireID: Dictionary<ObjectID, [Message]> = Dictionary(grouping: allRawInputMessages, by: { $0.wireID })

        var inputMessages = [NodeKindDescriptor.InputPort: [NodeMessage]]()

        let wiresOnAllInputs = try database.selectWires(goingToNodeID: node.nodeContext.nodeID!)
        let wiresGroupedByInputPort: Dictionary<UInt8, [Wire]> = Dictionary(grouping: wiresOnAllInputs, by: { $0.toPort })

        for inputPort in node.descriptor.inputs.filter({ if case .messageStream = $0.kind { return true } else { return false }}) {

            guard let wiresOnInputPort = wiresGroupedByInputPort[inputPort.index] else {
                inputMessages[inputPort] = []
                continue
            }

            var inputMessagesForThisPort = [NodeMessage]()

            for wire in wiresOnInputPort {
                for message in rawMessagesGroupedByWireID[wire.id!] ?? [] {

                   // let sourceNodeOutputValue = try database.selectNodeOutputValue(nodeID: wire.fromNodeID, port: wire.fromPort)

                    inputMessagesForThisPort.append(.init(originNodeID: message.targetNodeID,
                                                          originOutputPort: wire.toPort,
                                                          dataObjectHash: message.dataObjectHash))
                }
            }

            inputMessages[inputPort] = inputMessagesForThisPort
        }

        for message in allRawInputMessages {
            _ = try database.deleteMessage(messageID: message.id!) // TODO: error handling
        }

        return inputMessages
    }

    func readFromInputPort(_ inputPort: NodeKindDescriptor.InputPort, nodeID: ObjectID) throws -> [NodeValue] {
        let wiresOnThisInput = try database.selectWires(goingToNodeID: nodeID, toPort: inputPort.index)

        return try wiresOnThisInput.compactMap { wire in
            if let nodeOutputValue = try database.selectNodeOutputValue(nodeID: wire.fromNodeID, port: wire.fromPort) {
                return try nodeOutputValue.asNodeOutputValue()
            } else {
                return nil
            }
        }
    }

    func postMessageToOutputPort(_ outputPort: NodeKindDescriptor.OutputPort,
                                 message: MessageType,
                                 nodeID: ObjectID) throws {

        let wiresOnThisOutput = try database.selectWires(comingFromNodeID: nodeID,
                                                         fromPort: outputPort.index)

        for wire in wiresOnThisOutput {
            try database.insertMessage(.init(targetNodeID: wire.toNodeID,
                                             wireID: wire.id!,
                                             dataObjectHash: message.asDataObjectHash()))
            try scheduleNode(wire.toNodeID)
        }
    }

    func writePendingToAllOutputsOfNode(nodeID: ObjectID) throws {
        let node = try nodePoly(nodeID: nodeID)!

        for output in node.descriptor.outputs {
            if case .value = output.kind {
                try node.writeToOutputPort(output, value: .noValue(reason: .pending))
            }
        }
    }

    func writeToOutputPort(_ outputPort: NodeKindDescriptor.OutputPort,
                           value: NodeValueKind,
                           nodeID: ObjectID) throws {

        let (dataObjectHash, kind, metadata) = try value.mapNodeOutputValue()

        try database.insertOrReplaceNodeOutputValue(.init(nodeID: nodeID,
                                                          port: outputPort.index,
                                                          kind: kind,
                                                          dataObjectHash: dataObjectHash,
                                                          metadata: metadata?.toJSON()))

        let wiresOnThisOutput = try database.selectWires(comingFromNodeID: nodeID,
                                                         fromPort: outputPort.index)

        for wire in wiresOnThisOutput {
            try writePendingToAllOutputsOfNode(nodeID: wire.toNodeID)
        }

        try scheduleNode(nodeID)
    }
}

//extension Message {
//    func asNodeInputMessageKind() throws -> NodeMessageKind {
//        switch kind {
//        case .valueMutated:
//            return .valueMutated(delta: dataObjectHash)
//        case .error:
//            return .error(description: "TODO")
//        }
//    }
//}

extension DatabaseModels.NodeOutputValue {
    func asNodeOutputValue() throws -> NodeValue {
        .init(originNodeID: nodeID,
              originOutputPort: port,
              kind: try .init(nodeOutputValue: self))
    }
}

enum NodeOutputValueError: Error {
    case dataObjectHashNotSetOnNodeOutputValue
}

extension NodeValueKind {
    init(nodeOutputValue: DatabaseModels.NodeOutputValue) throws {
        switch nodeOutputValue.kind {
        case .pending:
            self = .noValue(reason: .pending)
        case .error:
            self = .noValue(reason: .error(message: "TODO")) // TODO
        case .value:
            if let dataObjectHash = nodeOutputValue.dataObjectHash {
                if let metadataJSON = nodeOutputValue.metadata {
                    self = .value(dataObjectHash: dataObjectHash, metadata: try PolyFactory.decode(encodedJSON: metadataJSON))
                } else {
                    self = .value(dataObjectHash: dataObjectHash, metadata: nil)
                }
            } else {
                throw NodeOutputValueError.dataObjectHashNotSetOnNodeOutputValue
            }
        }
    }

    // HACK
    func mapNodeOutputValue() throws -> (DataObjectHash?, DatabaseModels.NodeOutputValue.ValueKind, (any PolySerializable)?) {
        switch self
        {
        case .noValue(let reason):
            switch reason {
            case .pending:
                return (nil, .pending, nil)
            case .error://(let message)
                return (nil, .error, nil)
            }

        case .value(let value, let metadata):
            return (value, .value, metadata)
        }
    }
}

extension ProcessingCycle {

    // MARK: - ASCII Art Graph

    func printAll() throws {
        let allNodes = try database.selectAllNodes()
        let allWires = try database.selectAllWires()
        let allMessages = try database.selectAllMessages(limit: 10000)
        let allOutputValues = try database.selectAllNodeOutputValues(limit: 10000000)
        let allDataObjects = try database.selectAllDataObjects()

        // Index helpers
        let nodeByID: [ObjectID: Node] = Dictionary(uniqueKeysWithValues: allNodes.compactMap { node in node.id.map { ($0, node) } })
        let outputValuesByNodeID: [ObjectID: [DatabaseModels.NodeOutputValue]] = Dictionary(grouping: allOutputValues, by: { $0.nodeID })
        let messagesByTargetNodeID: [ObjectID: [Message]] = Dictionary(grouping: allMessages, by: { $0.targetNodeID })
        let wiresByFromNodeID: [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: { $0.fromNodeID })
        let wiresByToNodeID: [ObjectID: [Wire]] = Dictionary(grouping: allWires, by: { $0.toNodeID })

        // Resolve the descriptor for a raw node (port names)
        func descriptorFor(_ rawNode: Node) -> NodeKindDescriptor? {
            guard let node = try? wrapRawNodePoly(nodeRaw: rawNode) else { return nil }
            return node.descriptor
        }

        // Friendly node label
        func labelForNode(_ rawNode: Node) -> String {
            let name = rawNode.name ?? "?"
            let kindName = (try? PolyFactory.type(kind: rawNode.kind))
                .map { String(describing: $0) } ?? "kind:\(rawNode.kind)"
            return "\(name) [\(kindName)] #\(rawNode.id ?? -1)"
        }

        // Format an output value for display
        func formatOutputValue(_ outputValue: DatabaseModels.NodeOutputValue) -> String {
            switch outputValue.kind {
            case .value:
                let hash = outputValue.dataObjectHash ?? "nil"
                let shortHash = hash.count > 12 ? String(hash.prefix(12)) + "…" : hash
                return "✔ '\(shortHash)'"
            case .pending:    
                return "⏳ pending"
            case .error:      
                return "❌ error"
            }
        }

        // Format a message kind for display
//        func formatMessageKind(_ message: Message) -> String {
//            switch message.kind {
//            case .valueMutated:     return "📨 mutated"
//            case .error:            return "❌ error"
//            }
//        }

        // ───────────────────────────────────────────────────
        // Section 1: Node boxes
        // ───────────────────────────────────────────────────
        print("╔══════════════════════════════════════════════╗")
        print("║              BUILD GRAPH STATE               ║")
        print("╚══════════════════════════════════════════════╝")
        print()

        for rawNode in allNodes {
            guard let nodeID = rawNode.id else { continue }
            let label = labelForNode(rawNode)
            let descriptor = descriptorFor(rawNode)
            let inputPorts  = descriptor?.inputs  ?? []
            let outputPorts = descriptor?.outputs ?? []
            let incomingWires = wiresByToNodeID[nodeID] ?? []
            let outgoingWires = wiresByFromNodeID[nodeID] ?? []
            let pendingMessages = messagesByTargetNodeID[nodeID] ?? []
            let outputValues = outputValuesByNodeID[nodeID] ?? []

            // Build the content lines inside the box
            var contentLines = [String]()

            // Parent info
            if let parentNodeID = rawNode.parentNodeID {
                let parentName = nodeByID[parentNodeID]?.name ?? "?"
                contentLines.append("  parent: \(parentName) #\(parentNodeID)")
            }

            // Input ports
            if !inputPorts.isEmpty {
                contentLines.append("  ┌─ inputs ─────────────────────")
                for inputPort in inputPorts {
                    let connectedWires = incomingWires.filter { $0.toPort == inputPort.index }
                    if connectedWires.isEmpty {
                        contentLines.append("  │ ▸ :\(inputPort.index) \"\(inputPort.name)\"  (disconnected)")
                    } else {
                        for wire in connectedWires {
                            let sourceNodeName = nodeByID[wire.fromNodeID]?.name ?? "?"
                            contentLines.append("  │ ▸ :\(inputPort.index) \"\(inputPort.name)\"  ◀── #\(wire.fromNodeID) \"\(sourceNodeName)\" :\(wire.fromPort)")
                        }
                    }
                }
                contentLines.append("  └─────────────────────────────")
            }

            // Output ports + cached values
            if !outputPorts.isEmpty {
                contentLines.append("  ┌─ outputs ────────────────────")
                for outputPort in outputPorts {
                    let connectedWires = outgoingWires.filter { $0.fromPort == outputPort.index }
                    let outputValue = outputValues.first(where: { $0.port == outputPort.index })
                    let valueDescription = outputValue.map { formatOutputValue($0) } ?? "·"
                    if connectedWires.isEmpty {
                        contentLines.append("  │ ▹ :\(outputPort.index) \"\(outputPort.name)\"  [\(valueDescription)]  (no wires)")
                    } else {
                        for wire in connectedWires {
                            let destinationNodeName = nodeByID[wire.toNodeID]?.name ?? "?"
                            contentLines.append("  │ ▹ :\(outputPort.index) \"\(outputPort.name)\"  [\(valueDescription)]  ──▶ #\(wire.toNodeID) \"\(destinationNodeName)\" :\(wire.toPort)")
                        }
                    }
                }
                contentLines.append("  └─────────────────────────────")
            }

            // Pending messages
            if !pendingMessages.isEmpty {
                contentLines.append("  ┌─ pending messages (\(pendingMessages.count)) ──────")
                for message in pendingMessages {
                    contentLines.append("  │   via wire #\(message.wireID)")
                }
                contentLines.append("  └─────────────────────────────")
            }

            // Compute box width
            let contentWidth = max(label.count, (contentLines.map { $0.count }.max() ?? 0)) + 4
            let boxWidth = max(contentWidth, 40)

            // Draw the box
            let topBorder    = "┌" + String(repeating: "─", count: boxWidth) + "┐"
            let bottomBorder = "└" + String(repeating: "─", count: boxWidth) + "┘"
            let separator    = "├" + String(repeating: "─", count: boxWidth) + "┤"

            func padLine(_ text: String) -> String {
                let padding = boxWidth - text.count
                return "│ " + text + String(repeating: " ", count: max(0, padding - 1)) + "│"
            }

            print(topBorder)
            print(padLine("⬢ " + label))
            if !contentLines.isEmpty {
                print(separator)
                for contentLine in contentLines {
                    print(padLine(contentLine))
                }
            }
            print(bottomBorder)
            print()
        }

        // ───────────────────────────────────────────────────
        // Section 2: Wire list
        // ───────────────────────────────────────────────────
        if !allWires.isEmpty {
            print("──────────────────────────────────────────────")
            print("  WIRES (\(allWires.count))")
            print("──────────────────────────────────────────────")
            for wire in allWires {
                let fromNodeName = nodeByID[wire.fromNodeID]?.name ?? "?"
                let toNodeName   = nodeByID[wire.toNodeID]?.name ?? "?"
                print("  #\(wire.id ?? -1)  \"\(fromNodeName)\" :\(wire.fromPort)  ───▶  \"\(toNodeName)\" :\(wire.toPort)")
            }
            print("──────────────────────────────────────────────")
            print()
        }

        // ───────────────────────────────────────────────────
        // Section 3: Pending messages
        // ───────────────────────────────────────────────────
        print("──────────────────────────────────────────────")
        print("  PENDING MESSAGES (\(allMessages.count))")
        print("──────────────────────────────────────────────")
        for message in allMessages {
            let targetNodeName = nodeByID[message.targetNodeID]?.name ?? "?"
            print("    → \"\(targetNodeName)\" #\(message.targetNodeID)  wire=#\(message.wireID)")
        }
        print("──────────────────────────────────────────────")
        print()

        // ───────────────────────────────────────────────────
        // Section 4: Data objects
        // ───────────────────────────────────────────────────
        if !allDataObjects.isEmpty {
            print("──────────────────────────────────────────────")
            print("  DATA OBJECTS (\(allDataObjects.count))")
            print("──────────────────────────────────────────────")
            for dataObject in allDataObjects {
                let shortHash = dataObject.hash.count > 16 ? String(dataObject.hash.prefix(16)) + "…" : dataObject.hash
                print("│  🗄 \(shortHash)  \(dataObject.content.count) byte(s)")
            }
            print("──────────────────────────────────────────────")
            print()
        }

        // ───────────────────────────────────────────────────
        // Section 5: Output values
        // ───────────────────────────────────────────────────
        if !allOutputValues.isEmpty {
            print("──────────────────────────────────────────────")
            print("  OUTPUT VALUES (\(allOutputValues.count))")
            print("──────────────────────────────────────────────")
            for outputValue in allOutputValues {
                let node = nodeByID[outputValue.nodeID]!
                let nodeDecoded = try! PolyFactory.decode(encodedJSON: node.configuration!) as! NodeType
                print("  \(type(of: nodeDecoded)) \"\(node.name ?? "?")\" #\(outputValue.nodeID) \(nodeDecoded.descriptor.outputs[Int(outputValue.port)].name) (\(outputValue.port))  → \(formatOutputValue(outputValue))")
            }
            print("──────────────────────────────────────────────")
            print()
        }
    }
}
