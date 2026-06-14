
//
//  NodeProtocol.swift
//  build_system
//

import Foundation
import DatabaseModels

// MARK: - Protocols

struct ProcessCacheEntry: Codable {
    let outputValues: [String: NodeValue]
}

// A NodeFunction is the "brain" of a Node. Every Node has a read-only NodeFunction object serialized into it.
// Its state never changes after initial creation. This is intended to encourage state to be persisted entirely via Ports.
protocol NodeFunction: Codable, PolySerializable, WithDefaultInitializer, NodeInputReader, NodeOutputWriter {

    var descriptor: NodeFunctionDescriptor { get }
    var nodeContext: NodeContext! { get set }

    /// Updates all output values based on the current input values, and also
    /// processes and removes all messages that are queued on any message-stream input ports.
    func process() throws

    func willSave() throws
    func didSave() throws
}

extension NodeFunction {
    var nodeID: ObjectID {
        nodeContext.nodeID!
    }

    func buildCacheKeyPartFromOneInput(inputPort: String) throws -> String {
        try readAllValuesFromInputPort(inputPort)
            .sorted { $0.key < $1.key }
            .map { $0.value }
            .toJSON()
    }

    func buildCacheKeyFromAllInputs() throws -> String? {
        if descriptor.staticInputPorts.isEmpty {
            return ""
        }

        var aggregated = try toJSON()

        for inputPort in descriptor.staticInputPorts.sorted() {
            aggregated.append(try buildCacheKeyPartFromOneInput(inputPort: inputPort))
            aggregated.append("\n")
        }

        return Sha256.hash(Array(aggregated.utf8))
    }

    func loadAndWriteCachedOutputs(cacheKey: String?) throws -> Bool {

        guard let cacheKey else {
            return false
        }

        // HACK: StaticFileNode gets inputs from direct calls..
        if (self is StaticFileNode) {
            return false
        }

//        if !((self is ClangCompilerTool) || (self is ClangLinkerTool) || (self is ClangPreprocessorTool)) {
//            return false
//        }

        if descriptor.staticInputPorts.isEmpty {
            return false
        }

        if descriptor.staticOutputPorts.isEmpty {
            return false
        }

        guard let cacheEntry = try nodeContext.processingCycle.database.selectCacheEntry(hash: cacheKey) else {
            return false
        }

        guard let decodedCacheEntry = try? JSONDecoder().decode(ProcessCacheEntry.self, from: Data(cacheEntry.content)) else {
            return false
        }

        for outputPort in descriptor.staticOutputPorts {
            if let outputValue = decodedCacheEntry.outputValues[outputPort] {
                print("Using cached output for node \(self.description()), output port \(outputPort)")
                try writeToOutputPort(outputPort, value: outputValue)
            } else {
                // Invalid cache
                return false
            }
        }

        return true
    }

    func saveCacheForAllInputsAndOutputs(cacheKey: String?) throws {
        guard let cacheKey else {
            return
        }

        if descriptor.staticInputPorts.isEmpty {
            return
        }

        if descriptor.staticOutputPorts.isEmpty {
            return
        }

        var outputValues: [String: NodeValue] = [:]

        for outputPort in descriptor.staticOutputPorts {
            let value = try readFromOutputPort(outputPort)
            outputValues[outputPort] = value // we do not save NodeIDs
        }

        let cacheEntry = ProcessCacheEntry(outputValues: outputValues)
        let cacheEntryData = try cacheEntry.toJSON().data(using: .utf8)!
        try nodeContext.processingCycle.database.insertCacheEntry(.init(hash: cacheKey, content: [UInt8](cacheEntryData)))
    }

    func processWithPreCheck() throws {
        guard allInputsAreSatisfied() else {
            writeToOutputPortsOnError(NodeError.missingInput(name: "processWithPreCheck"))
            return
        }

        nodeContext.processingCycle.wiresModified = false
        let cacheKey = try buildCacheKeyFromAllInputs()

        if try !loadAndWriteCachedOutputs(cacheKey: cacheKey) {

            do {
                try process()
            } catch {
                writeToOutputPortsOnError(error)
            }

            if !nodeContext.processingCycle.wiresModified {
                try? saveCacheForAllInputsAndOutputs(cacheKey: cacheKey)
            }
        }
    }

    func writeToOutputPortsOnError(_ error: Error) {
        for outputPort in descriptor.staticOutputPorts {
            try? writeToOutputPort(outputPort, value: .noValue(reason: .error(message: "\(error)")))
        }
    }

    func allInputsAreSatisfied() -> Bool {
        for inputPort in descriptor.staticInputPorts {
            guard let values = try? readAllValuesFromInputPort(inputPort), !values.isEmpty else {
                return false
            }

            if values.contains(where: { if case .noValue = $0.value { return true } else { return false } }) {
                return false
            }
        }

        return true
    }
}

protocol WithDefaultInitializer {
    init() throws
}

protocol MessageType: AnyObject, Codable, PolySerializable {
}

// MARK: - PolyFactory + NodeFunction

extension PolyFactory {
    /// Construct a default instance of the type identified by `kind`.
    static func makeDefault(kind: UInt) throws -> NodeFunction {
        try (type(kind: kind) as! (PolySerializable & WithDefaultInitializer).Type).init() as! NodeFunction
    }
}

// MARK: - NodeContext

struct NodeContext {
    let processingCycle: ProcessingCycle
    var nodeID: ObjectID?           // nil when created in memory but not yet inserted
    var parentNodeID: ObjectID?
    var name: String? {
        didSet {
            assert(name == nil || name!.contains("/") == false)
        }
    }
    var searchKey: String?
}

// MARK: - NodeError

enum NodeError: Error {
    case nodeNotFound
    case onlyOneWireShouldBeConnectedToInput
    case missingInputs
    case missingInput(name: String)
    case other(message: String)
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

// MARK: - NodeFunction default implementations

extension NodeFunction {
    func willSave() throws {}
    func didSave() throws {}
}

extension NodeFunction {
    func description() -> String {
        "\(String(describing: Self.self)) (kind: \(type(of: self).kind)), NodeID: \(nodeContext.nodeID ?? -1), name: \(nodeContext.name ?? "nil"), inputs: \(descriptor.staticInputPorts.count), outputs: \(descriptor.staticOutputPorts.count)"
    }
}

struct OneNodeValue {
    let dataObjectHash: DataObjectHash
    let originNodeID: ObjectID
}

extension NodeFunction {
    /// Reads a PolySerializable configuration object from the given input port.
    /// Returns nil when no wire is connected or the wire has no value yet.
    func readConfiguration<C: PolySerializable>(fromInputPort inputPort: String) throws -> C {
        try PolyFactory.decodeAndCast(encodedJSON: readOneValueFromInputPort(inputPort).1.expectValue().resolveAsString())
    }
}

// MARK: - NodeFunction navigation / port helpers

extension NodeFunction {
    func parent<N: NodeFunction>() throws -> N? {
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

    func child(named name: String) throws -> (any NodeFunction)? {
        try nodeContext.processingCycle.nodePoly(named: name, parentNodeID: self.nodeID)
    }

    func delete() throws {
        if let nodeID = nodeContext.nodeID {
            _ = try nodeContext.processingCycle.deleteNode(nodeID)
        }
    }

    func noOutputWiresPreventCascadeDeletion() throws -> Bool {

        #warning("TODO")
        return true /*
        guard let wires = try? nodeContext.processingCycle.database.selectWires(comingFromNodeID: self.nodeID), !wires.isEmpty else {
            return true
        }

        for wire in wires {
            let toNode = try nodeContext.processingCycle.nodePoly(nodeID: wire.toNodeID)!

            let toNodeAllowsCascadingDelete = toNode.descriptor.inputs.first(where: { $0.index == wire.toPort })?.cascadingDelete ?? false

            if !toNodeAllowsCascadingDelete {
                return false
            }
        }

        return true*/
    }

    func readAllValuesFromInputPort(_ inputPort: String) throws -> [String: NodeValue] {
        try nodeContext.processingCycle.readFromInputPort(inputPort, nodeID: nodeID)
    }

    func readOneValueFromInputPort(_ inputPort: String) throws -> (String, NodeValue) {
        let values = try readAllValuesFromInputPort(inputPort)

        switch values.count {

        case 0:
            throw NodeError.missingInputs

        case 1:
            let first = values.first!
            return (first.key, first.value)

        default:
            throw NodeError.onlyOneWireShouldBeConnectedToInput
        }
    }

    func readFromOutputPort(_ outputPort: String) throws -> NodeValue {
        try nodeContext.processingCycle.readFromOutputPort(outputPort, nodeID: self.nodeID)
    }

    func writeToOutputPort(_ outputPort: String, value: NodeValue) throws {
        try nodeContext.processingCycle.writeToOutputPort(outputPort, value: value, nodeID: self.nodeID)
    }

    func allChildren() throws -> [NodeFunction] {
        try nodeContext.processingCycle.allChildNodes(nodeID: self.nodeID)
    }

    func childPoly(named name: String, kind: UInt, createIfNotExist: Bool = false) throws -> NodeFunction? {
        if let existingChild = try nodeContext.processingCycle.nodePoly(named: name, parentNodeID: self.nodeID) {
            return existingChild
        }
        if !createIfNotExist { return nil }
        return try nodeContext.processingCycle.makeNodePoly(kind: kind, name: name, parentNodeID: self.nodeID)
    }

    /// Creates the child if it does not exist.
    func child<N: NodeFunction>(named name: String, createIfNotExist: Bool = false) throws -> N? {
        if let existingChild: N = try nodeContext.processingCycle.node(named: name, parentNodeID: self.nodeID) {
            return existingChild
        }
        if !createIfNotExist { return nil }
        return try nodeContext.processingCycle.makeNodePoly(kind: N.kind, name: name, parentNodeID: self.nodeID) as! N?
    }

    /// Returns a child at a path (e.g. "example/src/main.swift"), this IS recursive.
    func child<N: NodeFunction>(path: String, createIfNotExist: Bool = false) throws -> N? {
        try nodeContext.processingCycle.childNode(path: path,
                                                  rootNodeID: self.nodeID,
                                                  createIfNotExist: createIfNotExist)
    }

    /// Returns a child at a path (e.g. "example/src/main.swift"), this IS recursive.
    func childPoly(path: String, kind: UInt, createIfNotExist: Bool = false) throws -> NodeFunction? {
        try nodeContext.processingCycle.childNodePoly(path: path,
                                                      rootNodeID: self.nodeID,
                                                      kind: kind,
                                                      createIfNotExist: createIfNotExist)
    }

    func findNodesConnectedToNodeViaInputWire(toInputSymbold inputSymbol: String) throws -> [any NodeFunction] {
        try nodeContext.processingCycle.findNodeConnectedToNodeViaInputWire(self, toInputSymbold: inputSymbol)
    }
}

// MARK: - PolySerializable helper

extension PolySerializable {
    func asDataObjectHash() throws -> DataObjectHash {
        (try toJSON()).intern()
    }
}
