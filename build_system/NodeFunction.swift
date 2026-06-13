
//
//  NodeProtocol.swift
//  build_system
//

import Foundation
import DatabaseModels

// MARK: - Protocols

struct ProcessCacheEntry: Codable {
    let outputValues: [String: NodeValueKind]
}

protocol NodeType: AnyObject, Codable, PolySerializable, WithDefaultInitializer {

    var descriptor: NodeKindDescriptor { get }
    var nodeContext: NodeContext! { get set }

    /// Updates all output values based on the current input values, and also
    /// processes and removes all messages that are queued on any message-stream input ports.
    func process() throws

    func willSave() throws
    func didSave() throws
}

extension NodeType {
    func buildCacheKeyPartFromOneInput(inputPort: InputPort) throws -> String {
        // Note: we zero-out the NodeID
        #warning("This should not reference surrogate IDs")
        let values = try readAllValuesFromInputPort(inputPort).sorted { a, b in a.originNodeID < b.originNodeID }.map { NodeValue(originNodeID: 0, originOutputPortDefID: $0.originOutputPortDefID, kind: $0.kind) }
        
        return try values.toJSON()
    }

    func buildCacheKeyFromAllInputs() throws -> String? {
        if descriptor.inputs.isEmpty {
            return ""
        }

        var aggregated = try toJSON()

        for inputPort in descriptor.inputs.sorted(by: { a, b in a.name < b.name }) {
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

        if descriptor.inputs.isEmpty {
            return false
        }

        if descriptor.outputs.isEmpty {
            return false
        }

        guard let cacheEntry = try nodeContext.processingCycle.database.selectCacheEntry(hash: cacheKey) else {
            return false
        }

        guard let decodedCacheEntry = try? JSONDecoder().decode(ProcessCacheEntry.self, from: Data(cacheEntry.content)) else {
            return false
        }

        for outputPort in descriptor.outputs {
            if let outputValue = decodedCacheEntry.outputValues[outputPort.name] {
                print("Using cached output for node \(self.description()), output port \(outputPort.name)")
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

        if descriptor.inputs.isEmpty {
            return
        }

        if descriptor.outputs.isEmpty {
            return
        }

        var outputValues: [String: NodeValueKind] = [:]

        for outputPort in descriptor.outputs {
            let value = try readFromOutputPort(outputPort)
            outputValues[outputPort.name] = value.kind // we do not save NodeIDs
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
        for outputPort in descriptor.outputs {
            try? writeToOutputPort(outputPort, value: .noValue(reason: .error(message: "\(error)")))
        }
    }

    func allInputsAreSatisfied() -> Bool {
        for inputPort in descriptor.inputs {
            if inputPort.minimumConnections > 0 {
                guard let values = try? readAllValuesFromInputPort(inputPort), !values.isEmpty else {
                    return false
                }

                if values.contains(where: { if case .noValue = $0.kind { return true } else { return false } }) {
                    return false
                }
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

// MARK: - PolyFactory + NodeType

extension PolyFactory {
    /// Construct a default instance of the type identified by `kind`.
    static func makeDefault(kind: UInt) throws -> NodeType {
        try (type(kind: kind) as! (PolySerializable & WithDefaultInitializer).Type).init() as! NodeType
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
    case portDefNotFound(name: String, kind: PortDef.PortKind)
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

// MARK: - NodeType default implementations

extension NodeType {
    func willSave() throws {}
    func didSave() throws {}
}

extension NodeType {
    func description() -> String {
        "\(String(describing: Self.self)) (kind: \(descriptor.kind)), NodeID: \(nodeContext.nodeID ?? -1), name: \(nodeContext.name ?? "nil"), inputs: \(descriptor.inputs.count), outputs: \(descriptor.outputs.count)"
    }
}

struct OneNodeValue {
    let dataObjectHash: DataObjectHash
    let originNodeID: ObjectID
}

// MARK: - NodeType navigation / port helpers

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

    func noOutputWiresPreventCascadeDeletion() throws -> Bool {

        #warning("TODO")
        return true /*
        guard let wires = try? nodeContext.processingCycle.database.selectWires(comingFromNodeID: nodeContext.nodeID!), !wires.isEmpty else {
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

    func readAllValuesFromInputPort(_ inputPort: InputPort) throws -> [NodeValueAndWire] {
        try nodeContext.processingCycle.readFromInputPort(inputPort, nodeID: nodeContext.nodeID!)
    }

    /// Returning nil means there is nothing yet connected to the input port
    /// (i.e. not that the value is not set).
    func readOneValueFromInputPort(_ inputPort: InputPort) throws -> OneNodeValue {
        let values = try readAllValuesFromInputPort(inputPort)

        switch values.count {

        case 0:
            throw NodeError.missingInputs

        case 1:
            switch values.first!.kind {

            case .noValue:
                throw NodeError.missingInputs

            case .value(let dataObjectHash):
                return .init(dataObjectHash: dataObjectHash, originNodeID: values.first!.originNodeID)
            }

        default:
            throw NodeError.onlyOneWireShouldBeConnectedToInput
        }
    }

    func readFromOutputPort(_ outputPort: OutputPort) throws -> NodeValue {
        try nodeContext.processingCycle.readFromOutputPort(outputPort, nodeID: nodeContext.nodeID!)
    }

    func writeToOutputPort(_ outputPort: OutputPort, value: NodeValueKind) throws {
        try nodeContext.processingCycle.writeToOutputPort(outputPort, value: value, nodeID: nodeContext.nodeID!)
    }

    func allChildren() throws -> [NodeType] {
        try nodeContext.processingCycle.allChildNodes(nodeID: nodeContext.nodeID!)
    }

    func childPoly(named name: String, kind: UInt, createIfNotExist: Bool = false) throws -> NodeType? {
        if let existingChild = try nodeContext.processingCycle.nodePoly(named: name, parentNodeID: nodeContext.nodeID!) {
            return existingChild
        }
        if !createIfNotExist { return nil }
        return try nodeContext.processingCycle.makeNodePoly(kind: kind, name: name, parentNodeID: nodeContext.nodeID!)
    }

    /// Creates the child if it does not exist.
    func child<N: NodeType>(named name: String, createIfNotExist: Bool = false) throws -> N? {
        if let existingChild: N = try nodeContext.processingCycle.node(named: name, parentNodeID: nodeContext.nodeID!) {
            return existingChild
        }
        if !createIfNotExist { return nil }
        return try nodeContext.processingCycle.makeNodePoly(kind: N.kind, name: name, parentNodeID: nodeContext.nodeID!) as! N?
    }

    /// Returns a child at a path (e.g. "example/src/main.swift"), this IS recursive.
    func child<N: NodeType>(path: String, createIfNotExist: Bool = false) throws -> N? {
        try nodeContext.processingCycle.childNode(path: path,
                                                  rootNodeID: nodeContext.nodeID!,
                                                  createIfNotExist: createIfNotExist)
    }

    /// Returns a child at a path (e.g. "example/src/main.swift"), this IS recursive.
    func childPoly(path: String, kind: UInt, createIfNotExist: Bool = false) throws -> NodeType? {
        try nodeContext.processingCycle.childNodePoly(path: path,
                                                      rootNodeID: nodeContext.nodeID!,
                                                      kind: kind,
                                                      createIfNotExist: createIfNotExist)
    }

    func findNodesConnectedToNodeViaInputWire(toInputPortNamed inputPortName: String) throws -> [any NodeType] {
        try nodeContext.processingCycle.findNodeConnectedToNodeViaInputWire(self, toInputPortNamed: inputPortName)
    }
}

// MARK: - PolySerializable helper

extension PolySerializable {
    func asDataObjectHash() throws -> DataObjectHash {
        (try toJSON()).intern()
    }
}
