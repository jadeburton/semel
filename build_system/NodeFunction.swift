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

protocol WithDefaultInitializer {
    init() throws
}

protocol InputlessNodeFunction: Codable, PolySerializable, WithDefaultInitializer {
    func didCreate(node: Node) throws -> ProcessOutput

    // When the Node is created, the InputlessNodeFunction is asked what "name" should be set to in the database.
    var initialName: String { get }

    var descriptor: NodeFunctionDescriptor { get }
    /// Returns the init-time key-value arguments that distinguish this node from
    /// others of the same type (e.g. `path='src/hello.c'` for StaticFile).
    /// Declared here so Swift dispatches it dynamically via the protocol witness table,
    /// not statically via the extension — which would always call the default `[]`.
    func graphShapeArgs(node: Node) -> [GraphShapeArg]
}

// A NodeFunction is the "brain" of a Node. Every Node has a read-only NodeFunction object serialized into it.
// Its state never changes after initial creation. This is intended to encourage state to be persisted entirely via Ports.
protocol NodeFunction: InputlessNodeFunction {
    func process(input: ProcessInput) throws -> ProcessOutput

    // Most Nodes can be immediately deleted as soon as all of their output wires are deleted. Deleting involves deleting all input Wires,
    // which may cause a cascade deletion.
    // Some Nodes should not be deleted even if they have no connected output Wires;
    // - ProjectFinder (which is the root object, and has no outputs by design)
    // - StaticFile. If StaticFile has content set, it must not be deleted even when there are no output Wires. However, if
    //   it has no content set (i.e. the user never pushed the file, or they deleted it) then it can be deleted if there are no output Wires.
    // - Folder. If it has one or more children it must not be deleted.
    func canBeDeleted(thisNode: Node) throws -> Bool
}

extension NodeFunction {

    func canBeDeleted(thisNode: Node) throws -> Bool {
        try hasNoOutputWires(thisNode: thisNode)
    }

    private func buildProcessInput(thisNode: Node) throws -> ProcessInput {
        var inputValues = [String: [String: NodeValue]]()
        for inputPort in descriptor.staticInputPorts + descriptor.dynamicInputPorts {
            inputValues[inputPort] = try thisNode.readFromInputPort(inputPort)
        }
        return .init(inputValues: inputValues)
    }

    private func allInputsAreSatisfied(input: ProcessInput) -> Bool {
        for inputPort in descriptor.staticInputPorts.filter({ !descriptor.optionalStaticInputPorts.contains($0) }) {
            guard let values = input.inputValues[inputPort], !values.isEmpty else { return false }
            if values.contains(where: { if case .noValue = $0.value { return true } else { return false } }) {
                return false
            }
        }
        return true
    }

    private func processWithCatch(thisNode: Node, input: ProcessInput) -> ProcessOutput {
        do {
            return try process(input: input)
        } catch {
            return buildErrorOutput(withError: error)
        }
    }

    func processWithPreCheck(thisNode: Node) {
        guard hasInputPorts() else {
            // Nodes without any input ports (not wires) cannot perform processing. This applies to StaticFiles.
            return
        }
        do {
            let input = try buildProcessInput(thisNode: thisNode)

            guard allInputsAreSatisfied(input: input) else {
                throw NodeError.missingInputs
            }

            let cacheKey = try buildCacheKeyFromAllInputs(input: input)

            if try !loadAndWriteCachedOutputs(thisNode: thisNode, cacheKey: cacheKey) {
                let output = processWithCatch(thisNode: thisNode, input: input)
                try writeToOutputs(output: output, thisNode: thisNode)
                validatePorts(node: thisNode)
                try? saveCacheForAllInputsAndOutputs(cacheKey: cacheKey, output: output)
            }
        } catch {
//            if case NodeError.missingInputs = error {
 //           } else {
//                print("Error during processing (\(thisNode.name!)): \(error)")
                try? writeToOutputs(output: buildErrorOutput(withError: error), thisNode: thisNode)
   //         }
        }
    }

    private func validatePorts(node: Node) {
        if !(try! DatabaseLayer.shared.selectAllOutputPorts(nodeID: node.id!).filter { $0.valueKind == .pending }.isEmpty) {
            print("WARNING: One or more outputs left Pending for node \(node)")
        }
    }
}

extension InputlessNodeFunction {

    func hasNoOutputWires(thisNode: Node) throws -> Bool {
        try DatabaseLayer.shared.selectWires(comingFromNodeID: thisNode.id!).isEmpty
    }

    func didCreate(node: Node) throws -> ProcessOutput {
        .init(outputValues: [:], inputWireExpectations: [:])
    }

    func writeToOutputs(output: ProcessOutput, thisNode: Node) throws {
        for (outputPort, outputValue) in output.outputValues {
            try thisNode.writeToOutputPort(outputPort, value: outputValue)
        }

        do {
            for (inputPort, wireExpectations) in output.inputWireExpectations {
                try applyExpectationConfiguration(inputPort: inputPort, wireExpectations: wireExpectations, thisNode: thisNode)
            }
        } catch {
            print("❌ ERROR: applyExpectationConfiguration failed: \(error)")
            throw error
        }
    }

    private func applyExpectationConfiguration(inputPort: String, wireExpectations: [String: String], thisNode: Node) throws {
        // 1. remove any wires that exist but are not in the new configuration (by name)
        // 2. add any wires that are in the new configuration but do not exist yet (by name)
        // 3. update expectation on wires that exist in both old and new configuration (by name)
        //    - obtain the current graph shape and compare against the configuration shape
        //    - if identical, do nothing
        //    - otherwise, disconnect the wire and treat it like a new connection (2)

        let toSymbolID   = inputPort.asSymbolID()
        let existingWires = try DatabaseLayer.shared.selectWires(goingToNodeID: thisNode.id!, toSymbolID: toSymbolID)

        // Build a lookup from wire name → existing Wire for steps 2 & 3.
        let existingWiresByName: [String: Wire] = Dictionary(
            uniqueKeysWithValues: existingWires.map { ($0.name.resolveSymbol(), $0) }
        )

        // Step 1 — delete wires whose name is absent from the new configuration.
        for (wireName, existingWire) in existingWiresByName {
            if wireExpectations[wireName] == nil {
                _ = try existingWire.deleteWire()
            }
        }

        // Steps 2 & 3 — iterate over the desired configuration.
        for (wireName, expectationString) in wireExpectations {

            // Shared helper: connect a new wire from the node that satisfies the expectation.
            let connectExpected = { [thisNode] in
                let wireNameSymbolID = wireName.asSymbolID()
                if let (fromNodeID, fromSymbolID) = try findExistingNodeMatchingExpectation(expectationString: expectationString) {
                    // fromSymbolID is nil when the expectation string has no .outputPort suffix,
                    // which is invalid for wiring — expectation strings must include a port.
                    guard let fromSymbolID else {
                        print("applyExpectationConfiguration: expectation '\(expectationString)' has no output port — cannot wire")
                        return
                    }

                    try Wire.connectWire(fromNodeID: fromNodeID,
                                            fromSymbolID: fromSymbolID,
                                            toNodeID: thisNode.id!,
                                            toSymbolID: toSymbolID,
                                            name: wireNameSymbolID)
                } else {
                    print("applyExpectationConfiguration: no node found matching expectation '\(expectationString)' for wire '\(wireName)' on input '\(inputPort)' of node #\(thisNode.id ?? -1)")
                }
            }

            if let existingWire = existingWiresByName[wireName] {
                // Step 3 — wire already exists; check whether its current graph shape
                // still satisfies the expectation.  Compare parsed shapes structurally
                // (port-order-independent, bracket-format-independent) rather than as
                // raw strings to avoid spurious mismatches.
                let currentShapeNode   = try GraphShapeNode.buildFromWire(existingWire)
                let expectedShapeNode  = try GraphShapeNode.parse(expectationString)
                guard !currentShapeNode.topologyMatches(expectedShapeNode) else {
                    continue   // topology unchanged — nothing to do
                }
                print("NO MATCH:")
                print("currentShapeNode: \(currentShapeNode.asString())")
                print("expectedShapeNode: \(expectedShapeNode.asString())")
                _ = try existingWire.deleteWire()
            }

            // Find and connect the matching source.
            try connectExpected()
        }
    }

    /// Parses `expectationString` into a `GraphShapeNode` and searches the live
    /// graph for a node whose type and recursive input wiring matches it,
    /// creating the required nodes and wires if none is found.
    /// Returns `(fromNodeID, fromSymbolID)` ready to pass to `connectWire`, or
    /// `nil` if the type name in the expectation is not registered in PolyFactory.
    private func findExistingNodeMatchingExpectation(expectationString: String) throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
        let expectedShape = try GraphShapeNode.parse(expectationString)
        return try expectedShape.findOrCreateMatchingNode()
    }

    /// Traverses the live graph backwards from `wire.fromNodeID / wire.fromSymbolID`
    /// and returns a compact string representation of the sub-graph shape, e.g.:
    ///   "ClangCompilerTool(configuration=StaticFile('config.json').output,
    ///                      input=ClangPreprocessorTool(...).output).output"
    /// The returned string can later be fed to `findExistingNodeMatchingExpectation`
    /// to locate the same (or structurally equivalent) node in the graph.
//    private func buildGraphShapeForInputWire(wire: Wire) throws -> String {
//        try GraphShapeNode.buildFromWire(wire).asString()
//    }

    fileprivate func buildErrorOutput(withError error: Error) -> ProcessOutput {
        var outputValues = [String: NodeValue]()
        for outputPort in descriptor.outputPorts {
            outputValues[outputPort] = .noValue(reason: .error(message: "\(error)"))
        }
        // Intentionally omit inputWireExpectations entirely.
        // Passing an empty dict per dynamic port would cause applyExpectationConfiguration
        // to delete every existing wire on those ports (step 1: delete wires not in config),
        // which reschedules upstream nodes, which recreate the wires, scheduling this node
        // again — an infinite loop.  Leave wire configuration completely untouched on error.
        return .init(outputValues: outputValues, inputWireExpectations: [:])
    }

    fileprivate func hasInputPorts() -> Bool {
        !descriptor.staticInputPorts.isEmpty || !descriptor.dynamicInputPorts.isEmpty
    }
}

protocol MessageType: AnyObject, Codable, PolySerializable {
}

// MARK: - NodeError

enum NodeError: Error {
    case nodeNotFound
    case onlyOneWireShouldBeConnectedToInput
    case missingInputs
    case missingInput(name: String)
    case other(message: String)
    case processNotSupported
    case cannotHaveProperties
    case cannotDeleteNodeWithOutputs
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

// MARK: - PolyFactory + NodeFunction

extension PolyFactory {
    /// Construct a default instance of the NodeFunction identified by `kind`.
    static func makeDefault(kind: UInt) throws -> InputlessNodeFunction {
        try (type(kind: kind) as! (PolySerializable & WithDefaultInitializer).Type).init() as! InputlessNodeFunction
    }

    static func makeDefault(kind: UInt, properties: [String: String]) throws -> InputlessNodeFunction & WithProperties {
        try (type(kind: kind) as! (PolySerializable & WithDefaultInitializer & WithProperties).Type).init(properties: properties) as! InputlessNodeFunction & WithProperties
    }
}

// MARK: - PolySerializable helper

extension PolySerializable {
    func asDataObjectHash() throws -> DataObjectHash {
        (try toJSON()).intern()
    }
}
