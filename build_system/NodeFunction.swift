
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

struct ProcessInput {
    let inputValues: [String: [String: NodeValue]]
}

struct ProcessOutput {
    let outputValues: [String: NodeValue]
    let inputWireExpectations: [String: [String: String]] // each dynamic input port has N wires connected to it, each wire has an expectation
}
/*
protocol NodeInputReader {
    func readAllValuesFromInputPort(_ inputPort: String) throws -> [String: NodeValue]
}

extension NodeInputReader {
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
}
*/

// A NodeFunction is the "brain" of a Node. Every Node has a read-only NodeFunction object serialized into it.
// Its state never changes after initial creation. This is intended to encourage state to be persisted entirely via Ports.
protocol NodeFunction: Codable, PolySerializable, WithDefaultInitializer {
    var descriptor: NodeFunctionDescriptor { get }
    func process(input: ProcessInput) throws -> ProcessOutput
}

extension NodeFunction {
    private func buildProcessInput(thisNode: Node, database: DatabaseLayer) throws -> ProcessInput {
        var inputValues = [String : [String : NodeValue]]()

        for inputPort in descriptor.staticInputPorts {
            inputValues[inputPort] = try thisNode.readFromInputPort(inputPort, database: database)
        }

        for inputPort in descriptor.dynamicInputPorts {
            inputValues[inputPort] = try thisNode.readFromInputPort(inputPort, database: database)
        }

        return .init(inputValues: inputValues)
    }

    private func writeToOutputs(output: ProcessOutput, thisNode: Node, database: DatabaseLayer) throws {
        for (outputPort, outputValue) in output.outputValues {
            try thisNode.writeToOutputPort(outputPort, value: outputValue, database: database)
        }
    }

    private func buildErrorOutput(withError error: Error) -> ProcessOutput {
        var outputValues = [String: NodeValue]()
        var inputWireExpectations = [String: [String: String]]()
        for outputPort in descriptor.outputPorts {
            outputValues[outputPort] = .noValue(reason: .error(message: "\(error)"))
        }
        for dynamicInputPort in descriptor.dynamicInputPorts {
            inputWireExpectations[dynamicInputPort] = [:] // TODO?
        }
        return .init(outputValues: outputValues, inputWireExpectations: inputWireExpectations)
    }

    private func processWithCatch(thisNode: Node, input: ProcessInput) -> ProcessOutput {
        do {
            return try process(input: input)
        } catch {
            return buildErrorOutput(withError: error)
        }
    }

    private func processWithPreCheck(thisNode: Node) throws {
        guard hasInputPorts() else {
            // Nodes without any input ports (not wires) cannot perform processing. This applies to StaticFiles.
            return
        }
        let input = try buildProcessInput(thisNode: thisNode)

        guard allInputsAreSatisfied(input: input) else {
            try writeToOutputs(output: buildErrorOutput(withError: NodeError.missingInputs), nodeContext: nodeContext)
            return
        }


        let cacheKey = try buildCacheKeyFromAllInputs(input: input)

        if try !loadAndWriteCachedOutputs(nodeContext: nodeContext, cacheKey: cacheKey) {

            let output = processWithCatch(nodeContext: nodeContext, input: input)

            try writeToOutputs(output: output, nodeContext: nodeContext)

            try? saveCacheForAllInputsAndOutputs(nodeContext: nodeContext, cacheKey: cacheKey, output: output)
        }
    }

    private func hasInputPorts() -> Bool {
        !descriptor.staticInputPorts.isEmpty || !descriptor.dynamicInputPorts.isEmpty
    }

    private func allInputsAreSatisfied(input: ProcessInput) -> Bool {
        for inputPort in descriptor.staticInputPorts + descriptor.dynamicInputPorts {
            guard let values = input.inputValues[inputPort], !values.isEmpty else {
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

//struct NodeContext {
//    let processingCycle: ProcessingCycle
//    var nodeID: ObjectID?           // nil when created in memory but not yet inserted
//    var parentNodeID: ObjectID?
//    var name: String? {
//        didSet {
//            assert(name == nil || name!.contains("/") == false)
//        }
//    }
//    var searchKey: String?
//}

// MARK: - NodeError

enum NodeError: Error {
    case nodeNotFound
    case onlyOneWireShouldBeConnectedToInput
    case missingInputs
    case missingInput(name: String)
    case other(message: String)
    case processNotSupported
}

// MARK: - NodeFunction default implementations

extension NodeFunction {
    func willSave() throws {}
    func didSave() throws {}
}

extension NodeFunction {
    func description() -> String {
        "\(String(describing: Self.self)) (kind: \(type(of: self).kind)), staticInputPorts: \(descriptor.staticInputPorts.count), outputPorts: \(descriptor.outputPorts.count), dynamicInputPorts: \(descriptor.dynamicInputPorts.count)"
    }
}

struct OneNodeValue {
    let dataObjectHash: DataObjectHash
    let originNodeID: ObjectID
}

extension NodeFunction {
    /// Reads a PolySerializable configuration object from the given input port.
    /// Returns nil when no wire is connected or the wire has no value yet.
//    func readConfiguration<C: PolySerializable>(fromInputPort inputPort: String) throws -> C {
//        try PolyFactory.decodeAndCast(encodedJSON: readOneValueFromInputPort(inputPort).1.expectValue().resolveAsString())
//    }
}

// MARK: - NodeFunction navigation / port helpers


extension NodeFunction {
//    func parent<N: NodeFunction>() throws -> N? {
//        try nodeContext.processingCycle.parentNode(node: self)
//    }

//    func save() throws {
//        try nodeContext.processingCycle.saveNode(self)
//    }


//    func child(named name: String, nodeContext: NodeContext) throws -> (any NodeFunction)? {
//        try nodeContext.processingCycle.nodePoly(named: name, parentNodeID: nodeContext.nodeID!)
//    }

//    func delete(nodeContext: NodeContext) throws {
//        if let nodeID = nodeContext.nodeID {
//            _ = try nodeContext.processingCycle.deleteNode(nodeID)
//        }
//    }

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

//    func readAllValuesFromInputPort(_ inputPort: String, nodeContext) throws -> [String: NodeValue] {
//        try nodeContext.processingCycle.readFromInputPort(inputPort, nodeID: nodeID)
//    }
//
//    func readFromOutputPort(_ outputPort: String) throws -> NodeValue {
//        try nodeContext.processingCycle.readFromOutputPort(outputPort, nodeID: self.nodeID)
//    }
//
//    func writeToOutputPort(_ outputPort: String, value: NodeValue) throws {
//        try nodeContext.processingCycle.writeToOutputPort(outputPort, value: value, nodeID: self.nodeID)
//    }
//
//    func allChildren() throws -> [NodeFunction] {
//        try nodeContext.processingCycle.allChildNodes(nodeID: self.nodeID)
//    }
/*
    func childPoly(named name: String, kind: UInt, createIfNotExist: Bool = false, nodeContext: NodeContext) throws -> NodeFunction? {
        if let existingChild = try nodeContext.processingCycle.nodePoly(named: name, parentNodeID: nodeContext.nodeID!) {
            return existingChild
        }
        if !createIfNotExist { return nil }
        return try nodeContext.processingCycle.makeNodeFunctionPoly(kind: kind, name: name, parentNodeID: nodeContext.nodeID!)
    }

    /// Creates the child if it does not exist.
    func child<N: NodeFunction>(named name: String, createIfNotExist: Bool = false, nodeContext: NodeContext) throws -> N? {
        if let existingChild: N = try nodeContext.processingCycle.node(named: name, parentNodeID: nodeContext.nodeID!) {
            return existingChild
        }
        if !createIfNotExist { return nil }
        return try nodeContext.processingCycle.makeNodeFunctionPoly(kind: N.kind, name: name, parentNodeID: nodeContext.nodeID!) as! N?
    }

    /// Returns a child at a path (e.g. "example/src/main.swift"), this IS recursive.
    func child<N: NodeFunction>(path: String, createIfNotExist: Bool = false, nodeContext: NodeContext) throws -> N? {
        try nodeContext.processingCycle.childNode(path: path,
                                                  rootNodeID: nodeContext.nodeID!,
                                                  createIfNotExist: createIfNotExist)
    }

    /// Returns a child at a path (e.g. "example/src/main.swift"), this IS recursive.
    func childPoly(path: String, kind: UInt, createIfNotExist: Bool = false, nodeContext: NodeContext) throws -> NodeFunction? {
        try nodeContext.processingCycle.childNodePoly(path: path,
                                                      rootNodeID: nodeContext.nodeID!,
                                                      kind: kind,
                                                      createIfNotExist: createIfNotExist)
    }
*/
}

// MARK: - PolySerializable helper

extension PolySerializable {
    func asDataObjectHash() throws -> DataObjectHash {
        (try toJSON()).intern()
    }
}
