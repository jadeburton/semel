
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

protocol InputlessNodeFunction: Codable, PolySerializable, WithDefaultInitializer {
    var descriptor: NodeFunctionDescriptor { get }
}

// A NodeFunction is the "brain" of a Node. Every Node has a read-only NodeFunction object serialized into it.
// Its state never changes after initial creation. This is intended to encourage state to be persisted entirely via Ports.
protocol NodeFunction: InputlessNodeFunction {
    func process(input: ProcessInput) throws -> ProcessOutput
}

extension NodeFunction {
    private func buildProcessInput(thisNode: Node) throws -> ProcessInput {
        var inputValues = [String : [String : NodeValue]]()

        for inputPort in descriptor.staticInputPorts {
            inputValues[inputPort] = try thisNode.readFromInputPort(inputPort)
        }

        for inputPort in descriptor.dynamicInputPorts {
            inputValues[inputPort] = try thisNode.readFromInputPort(inputPort)
        }

        return .init(inputValues: inputValues)
    }

    private func writeToOutputs(output: ProcessOutput, thisNode: Node) throws {
        for (inputPort, wireExpectations) in output.inputWireExpectations {
            try applyExpectationConfiguration(inputPort: inputPort, wireExpectations: wireExpectations, thisNode: thisNode)
        }
        for (outputPort, outputValue) in output.outputValues {
            try thisNode.writeToOutputPort(outputPort, value: outputValue)
        }
    }

    private func applyExpectationConfiguration(inputPort: String, wireExpectations: [String: String], thisNode: Node) throws {
        // 1. remove any wires that exist but are not in the new configuration (by name)
        // 2. add any wires that are in the new configuration but do not exist yet (by name)
        // 3. update expectation on wires that exist in both old and new configuration (by name)
        //    - obtain the current graph shape and compare against the configuration shape
        //    - if identical, do nothing
        //    - otherwise, disconnect the wire and treat it like a new connection (2)

        let wiresOnThisInput = try DatabaseLayer.shared.selectWires(goingToNodeID: thisNode.id!, toSymbolID: inputPort.asSymbolID())

        var result = [String: NodeValue]()

        for wire in wiresOnThisInput {
            let wireName = wire.name.resolveSymbol()

            if wireExpectations[wireName] == nil {
                // this wire is not in the new configuration; delete it
                _ = try wire.deleteWire()
            }
        }

        // TODO: finish this method

        // NOTE: the representation of the expectation configuration is not yet defined and is still to be done. For now let's
        // just call a dummy method that returns a fixed configuration that matches the current graph shape, so that we can proceed with testing the rest of the processing cycle.
        
        // TODO: add a second dummy method that receives an expectation configuration and locates a Node somewhere on the graph
        // whose output matches it. We then wire from that Node to our input.
        
        return result

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

    func processWithPreCheck(thisNode: Node) throws {
        guard hasInputPorts() else {
            // Nodes without any input ports (not wires) cannot perform processing. This applies to StaticFiles.
            return
        }
        let input = try buildProcessInput(thisNode: thisNode)

        guard allInputsAreSatisfied(input: input) else {
            print("Not all inputs are satisfied. \(thisNode.name!)")
            try writeToOutputs(output: buildErrorOutput(withError: NodeError.missingInputs), thisNode: thisNode)
            return
        }

        let cacheKey = try buildCacheKeyFromAllInputs(input: input)

        if try !loadAndWriteCachedOutputs(thisNode: thisNode, cacheKey: cacheKey) {
            let output = processWithCatch(thisNode: thisNode, input: input)
            try writeToOutputs(output: output, thisNode: thisNode)
            try? saveCacheForAllInputsAndOutputs(cacheKey: cacheKey, output: output)
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
    static func makeDefault(kind: UInt) throws -> InputlessNodeFunction {
        try (type(kind: kind) as! (PolySerializable & WithDefaultInitializer).Type).init() as! InputlessNodeFunction
    }
}

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

// MARK: - PolySerializable helper

extension PolySerializable {
    func asDataObjectHash() throws -> DataObjectHash {
        (try toJSON()).intern()
    }
}
