//
//  NodeProtocol.swift
//  build_system
//

import Foundation
import DatabaseModels

// MARK: - Protocols

struct ProcessCacheEntry: Codable {
    let outputValues: [String: NodeValue]
    let inputWireExpectations: [String: [String: String]]
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

extension InputlessNodeFunction {
    var thisNode: Node {
        embeddedNode!
    }

    var id: ObjectID? {
        thisNode.id
    }

    var parentNodeID: ObjectID? {
        thisNode.parentNodeID
    }

    var scheduled: Bool {
        thisNode.scheduled
    }

    var searchKey: String? {
        thisNode.searchKey
    }
}

protocol InputlessNodeFunction: WithKind {
    var embeddedNode: Node? { get set }

    init(thisNode: Node) throws

    func didCreate() throws -> ProcessOutput?

    var descriptor: NodeFunctionDescriptor { get }

    /// Returns the init-time key-value arguments that distinguish this node from
    /// others of the same type (e.g. `path='src/hello.c'` for StaticFile).
    /// Declared here so Swift dispatches it dynamically via the protocol witness table,
    /// not statically via the extension — which would always call the default `[]`.
    func graphShapeArgs(node: Node) -> [GraphShapeArg]

    // Most Nodes can be immediately deleted as soon as all of their output wires are deleted. Deleting involves deleting all input Wires,
    // which may cause a cascade deletion.
    // Some Nodes should not be deleted even if they have no connected output Wires;
    // - ProjectFinder (which is the root object, and has no outputs by design)
    // - StaticFile. If StaticFile has content set, it must not be deleted even when there are no output Wires. However, if
    //   it has no content set (i.e. the user never pushed the file, or they deleted it) then it can be deleted if there are no output Wires.
    // - If the Node (usually a Folder) has one or more children it must not be deleted. (If a Node is deleted, we must check if it's parent can be deleted.)
    func canBeDeleted() throws -> Bool

    func onChildAdded(nodeID: ObjectID) throws
    func onChildContentChanged(nodeID: ObjectID, name: String) throws
    func onChildDeleted(nodeID: ObjectID) throws
}

protocol NodeFunction: InputlessNodeFunction {
    func process(input: ProcessInput) throws -> ProcessOutput
}

extension NodeFunction {

    private func buildProcessInput() throws -> ProcessInput {
        var inputValues = [String: [String: NodeValue]]()
        for inputPort in descriptor.staticInputPorts + descriptor.dynamicInputPorts {
            inputValues[inputPort] = try thisNode.readFromInputPort(inputPort)
        }
        return .init(inputValues: inputValues)
    }

    private func allInputsAreSatisfied(input: ProcessInput) throws -> Bool {
        for inputPort in descriptor.staticInputPorts.filter({ !descriptor.optionalStaticInputPorts.contains($0) }) {

            guard let values = input.inputValues[inputPort] else {
                throw NodeError.other(message: "inputValues is missing an entry for input port")
            }

            guard !values.isEmpty else {
                // The input port is non-optional. Therefore it is a serious integrity error for it to not be connected.
                // TODO: self-healing
                print("WARNING: non-optional input port \(inputPort) has no connected wires")
                return false
            }

            if values.contains(where: { $0.value.isPending }) {
                return false
            }
        }
        return true
    }

    private func processWithCatch(input: ProcessInput) -> ProcessOutput {
        do {
            print("process: \(type(of: self)), nodeID \(id!)")
            return try process(input: input)
        } catch {
            return buildErrorOutput(withError: error)
        }
    }

    func processWithPreCheck() throws {
        guard hasInputPorts() else {
            // Nodes without any input ports (not wires) cannot perform processing. This applies to StaticFiles.
            return
        }

        // Gather all values from input ports
        let input = try buildProcessInput()

        guard try allInputsAreSatisfied(input: input) else {
            //print("Not all inputs are satisfied.")
            return
        }

        let cacheKey = try? buildCacheKeyFromAllInputs(input: input)

        if let cachedOutput = try? loadCachedOutputs(cacheKey: cacheKey) {
            // BUG: this fails and then the Node keeps being processed forever.
            try? writeToOutputs(output: cachedOutput)
        } else {

            let startTime = Date.now
            let output = processWithCatch(input: input)
            try? writeToOutputs(output: output)

            try? saveCacheForAllInputsAndOutputs(cacheKey: cacheKey,
                                                 processingDuration: Date.now.timeIntervalSince(startTime),
                                                 output: output)
        }
    }
}

extension InputlessNodeFunction {
    func onChildAdded(nodeID: ObjectID) throws {
    }

    func onChildDeleted(nodeID: ObjectID) throws {
    }

    func onChildContentChanged(nodeID: ObjectID, name: String) throws {
    }

    var parentNodeFunction: InputlessNodeFunction? {
        get throws {
            if let parentNodeID = thisNode.parentNodeID {
                return try database.node.select(nodeID: parentNodeID).nodeFunction()
            }
            return nil
        }
    }

    func notifyParentThisChildAdded() throws {
        try parentNodeFunction?.onChildAdded(nodeID: thisNode.id!)
    }

    func notifyParentOfChildContentChange() throws {
        try parentNodeFunction?.onChildContentChanged(nodeID: thisNode.id!, name: thisNode.name!)
    }

    func notifyParentOfChildDeletion() throws {
        try parentNodeFunction?.onChildDeleted(nodeID: thisNode.id!)
    }

    func delete() throws {
        let safeToDelete = try hasNoOutputWires() && hasNoInputWires()
        assert(safeToDelete)
        _ = try database.node.delete(nodeID: id!)
        try notifyParentOfChildDeletion()
    }

    var database: DatabaseLayer {
        DatabaseLayer.shared
    }

    func canBeDeleted() throws -> Bool {
        true
    }

    func hasNoOutputWires() throws -> Bool {
        try database.wire.select(comingFromNodeID: id!).isEmpty
    }

    func hasNoInputWires() throws -> Bool {
        try database.wire.select(goingToNodeID: id!).isEmpty
    }

    func didCreate() throws -> ProcessOutput? {
        nil
    }

    func writeToOutputs(output: ProcessOutput) throws {

        let numberOfOutputPorts = try! database.outputPort.selectAll(nodeID: id!).count

        if numberOfOutputPorts != output.outputValues.count {
            print("WARNING: Mismatch between number of output values (\(output.outputValues.count)) and number of output ports (\(numberOfOutputPorts)) for node \(thisNode)")
        }

        if numberOfOutputPorts != descriptor.outputPorts.count {
            print("WARNING: Mismatch between number of outputs defined in the Descriptor (\(descriptor.outputPorts.count)) and number of output ports (\(numberOfOutputPorts)) for node \(thisNode)")
        }

        for (outputPort, outputValue) in output.outputValues {
            if outputValue.isPending {
                print("WARNING: Output left Pending for node \(thisNode): outputPort \(outputPort)")
            }
            try thisNode.writeToOutputPort(outputPort, value: outputValue)
        }

        do {
            for (inputPort, wireExpectations) in output.inputWireExpectations {
                try applyExpectationConfiguration(inputPort: inputPort, wireExpectations: wireExpectations)
            }
        } catch {
            print("❌ ERROR: applyExpectationConfiguration failed: \(error)")
            for outputPort in try descriptor.outputPorts {
                try thisNode.writeToOutputPort(outputPort, value: .noValue(reason: .error(message: "applyExpectationConfiguration failed")))
            }
            throw error
        }
    }

    private func applyExpectationConfiguration(inputPort: String, wireExpectations: [String: String]) throws {
        // 1. remove any wires that exist but are not in the new configuration (by name)
        // 2. add any wires that are in the new configuration but do not exist yet (by name)
        // 3. update expectation on wires that exist in both old and new configuration (by name)
        //    - obtain the current graph shape and compare against the configuration shape
        //    - if identical, do nothing
        //    - otherwise, disconnect the wire and treat it like a new connection (2)

        let toSymbolID   = inputPort.asSymbolID()
        let existingWires = try database.wire.select(goingToNodeID: id!, toSymbolID: toSymbolID)

        // Build a lookup from wire name → existing Wire for steps 2 & 3.
        let existingWiresByName: [String: Wire] = Dictionary(
            uniqueKeysWithValues: existingWires.map { ($0.name.resolveSymbol(), $0) }
        )

        // Step 1 — delete wires whose name is absent from the new configuration.
        for (wireName, existingWire) in existingWiresByName {
            if wireExpectations[wireName] == nil {
                _ = try existingWire.deleteWire(database: database)
            }
        }

        // Steps 2 & 3 — iterate over the desired configuration.
        for (wireName, expectationString) in wireExpectations {

            // Shared helper: connect a new wire from the node that satisfies the expectation.
            let connectExpected = {
                let wireNameSymbolID = wireName.asSymbolID()
                if let (fromNodeID, fromSymbolID) = try findExistingOrCreateNodeMatchingExpectation(expectationString) {
                    // fromSymbolID is nil when the expectation string has no .outputPort suffix,
                    // which is invalid for wiring — expectation strings must include a port.
                    guard let fromSymbolID else {
                        print("applyExpectationConfiguration: expectation '\(expectationString)' has no output port — cannot wire")
                        return
                    }

                    try Wire.connectWire(database: database,
                                         fromNodeID: fromNodeID,
                                         fromSymbolID: fromSymbolID,
                                         toNodeID: id!,
                                         toSymbolID: toSymbolID,
                                         name: wireNameSymbolID)
                } else {
                    print("applyExpectationConfiguration: no node found matching expectation '\(expectationString)' for wire '\(wireName)' on input '\(inputPort)' of node #\(id ?? -1)")
                }
            }

            if let existingWire = existingWiresByName[wireName] {
                // Step 3 — wire already exists; check whether its current graph shape
                // still satisfies the expectation.  Compare parsed shapes structurally
                // (port-order-independent, bracket-format-independent) rather than as
                // raw strings to avoid spurious mismatches.
                let currentShapeNode   = try GraphShapeNode.buildFromWire(existingWire, database: database)
                let expectedShapeNode  = try GraphShapeNode.parse(expectationString)
                var log: String? = ""

                // Throws if there is a mismatch. If that happens, it means there is an integrity problem; the searchKey does
                // not match what we actually created, probably because we failed to exactly create the graph shape.
                try currentShapeNode.expectTopologyMatch(expectedShapeNode)
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
    private func findExistingOrCreateNodeMatchingExpectation(_ expectationString: String) throws -> (fromNodeID: ObjectID, fromSymbolID: ObjectID?)? {
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

    func buildErrorOutput(withError error: Error) -> ProcessOutput {
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
    case initializing
    case searchKeyBadIntegrity(currentShapeNode: String, expectedShapeNode: String, log: String)

}
extension NodeFunction {
    func description() -> String {
        "\(String(describing: Self.self)) (\(type(of: self))), staticInputPorts: \(descriptor.staticInputPorts.count), outputPorts: \(descriptor.outputPorts.count), dynamicInputPorts: \(descriptor.dynamicInputPorts.count)"
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
