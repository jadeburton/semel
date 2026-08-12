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

public struct ProcessOutput {
    public let outputValues: [String: NodeValue]
    public let inputWireExpectations: [String: [String: String]] // each dynamic input port has N wires connected to it, each wire has an expectation
}

protocol WithDefaultInitializer {
    init() throws
}

extension InputlessNodeFunction {
    var thisNode: Node {
        embeddedNode
    }

    var id: ObjectID? {
        thisNode.id
    }

    /// The node's id, or an integrity error if it has not been persisted yet.
    func requireID() throws -> ObjectID {
        try thisNode.requireID()
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
    var embeddedNode: Node { get set }

    init(thisNode: Node) throws

    func didCreate() throws -> ProcessOutput?

    static var descriptor: NodeFunctionDescriptor { get }

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

    /// Called immediately before the node is permanently removed from the DB.
    /// Default implementation is a no-op; override to perform cleanup or logging.
    func willBeDeleted() throws

    /// Called at the end of `writeToOutputs`, after all output port values have
    /// been written to the DB.  Default implementation is a no-op; override to
    /// react to the written output without mutating the Node itself.
    func didWriteOutputs(output: ProcessOutput) throws
}

extension InputlessNodeFunction {
    var descriptor: NodeFunctionDescriptor { Self.descriptor }
}

protocol NodeFunction: InputlessNodeFunction {
    /// Increment this to invalidate cached outputs when processing logic changes.
    /// Defaults to 0; override in any NodeFunction whose output format changes.
    static var codeVersion: Int { get }
    func process(input: ProcessInput) throws -> ProcessOutput
}

extension NodeFunction {
    static var codeVersion: Int { 0 }
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
                throw NodeError.other(message: "inputValues is missing an entry for input port \(inputPort)")
            }

            guard !values.isEmpty else {
                // GraphShapeApplier.createNode() validates this at creation time (requiredPortUnwired),
                // so reaching here means a wire was removed after the node was built — a real integrity error.
                throw NodeError.other(message: "Non-optional input port '\(inputPort)' has no connected wires for \(self)")
            }

            if values.contains(where: { $0.value.isPending }) {
                return false
            }
        }

        // Optional ports with no wires are fine to skip, but if wires ARE connected
        // and any carry a pending value the node must wait — the optional port's data
        // is required for correct processing once it exists.
        for inputPort in descriptor.optionalStaticInputPorts {
            guard let values = input.inputValues[inputPort], !values.isEmpty else { continue }
            if values.contains(where: { $0.value.isPending }) {
                return false
            }
        }

        // Dynamic ports (e.g. source files) with pending values also block processing —
        // a file mid-upload would give the compiler an incomplete input set.
        for inputPort in descriptor.dynamicInputPorts {
            guard let values = input.inputValues[inputPort], !values.isEmpty else { continue }
            if values.contains(where: { $0.value.isPending }) {
                return false
            }
        }

        return true
    }

    private func processWithCatch(input: ProcessInput) -> ProcessOutput {
        do {
            print("process: \(type(of: self)), nodeID \(try requireID())")
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
        var didWriteCachedOutput = false

        if let cachedOutput = try? loadCachedOutputs(cacheKey: cacheKey) {
            do {
                try writeToOutputs(output: cachedOutput)
                didWriteCachedOutput = true
            } catch {
                // Cached output is stale or the graph topology changed — fall
                // through and reprocess so the node does not stay stuck.
                print("WARNING: writeToOutputs failed for cached output, reprocessing: \(error)")
            }
        }

        if !didWriteCachedOutput {
            let startTime = Date.now
            let output = processWithCatch(input: input)
            try writeToOutputs(output: output)
            try? saveCacheForAllInputsAndOutputs(cacheKey: cacheKey,
                                                 processingDuration: Date.now.timeIntervalSince(startTime),
                                                 output: output)
        }
    }

    /// Phase 1 of two-phase parallel processing: reads inputs and computes the
    /// output without making any graph mutations.  Safe to call concurrently with
    /// other nodes.  Returns nil if this node is not ready to process (no input
    /// ports, inputs pending, required wires missing, etc.).
    func tryComputeOutput() -> (output: ProcessOutput, cacheKey: String?, fromCache: Bool, computeStart: Date)? {
        guard hasInputPorts() else { return nil }
        guard let input = try? buildProcessInput() else { return nil }
        guard (try? allInputsAreSatisfied(input: input)) == true else { return nil }

        let cacheKey = try? buildCacheKeyFromAllInputs(input: input)

        if let cached = try? loadCachedOutputs(cacheKey: cacheKey) {
            return (cached, cacheKey, true, .now)
        }

        let computeStart = Date.now
        return (processWithCatch(input: input), cacheKey, false, computeStart)
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
        try parentNodeFunction?.onChildAdded(nodeID: (try thisNode.requireID()))
    }

    func notifyParentOfChildContentChange() throws {
        try parentNodeFunction?.onChildContentChanged(nodeID: (try thisNode.requireID()), name: thisNode.name!)
    }

    func notifyParentOfChildDeletion() throws {
        try parentNodeFunction?.onChildDeleted(nodeID: (try thisNode.requireID()))
    }

    func willBeDeleted() throws { }

    func didWriteOutputs(output: ProcessOutput) throws { }

    func delete() throws {
        let safeToDelete = try hasNoOutputWires() && hasNoInputWires()
        assert(safeToDelete)
        try willBeDeleted()
        _ = try database.node.delete(nodeID: (try requireID()))
        try notifyParentOfChildDeletion()
    }

    var database: DatabaseLayer {
        DatabaseLayer.shared
    }

    func canBeDeleted() throws -> Bool {
        true
    }

    func hasNoOutputWires() throws -> Bool {
        try database.wire.select(comingFromNodeID: (try requireID())).isEmpty
    }

    func hasNoInputWires() throws -> Bool {
        try database.wire.select(goingToNodeID: (try requireID())).isEmpty
    }

    func didCreate() throws -> ProcessOutput? {
        nil
    }

    func writeToOutputs(output: ProcessOutput) throws {

        let numberOfOutputPorts = try database.outputPort.selectAll(nodeID: (try requireID())).count

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

        try didWriteOutputs(output: output)

        do {
            for (inputPort, wireExpectations) in output.inputWireExpectations {
                try applyExpectationConfiguration(inputPort: inputPort, wireExpectations: wireExpectations)
            }
        } catch {
            #if DEBUG
            print("applyExpectationConfiguration failed: \(error)")
            #endif
            for outputPort in try descriptor.outputPorts {
                try thisNode.writeToOutputPort(outputPort, value: .noValue(reason: .error(message: "\(error)")))
            }
            throw error
        }
    }

    private func applyExpectationConfiguration(inputPort: String, wireExpectations: [String: String]) throws {
        // 1. remove any wires that exist but are not in the new configuration (by name)
        // 2. add any wires that are in the new configuration but do not exist yet (by name)
        // 3. update expectation on wires that exist in both old and new configuration (by name)
        //    - obtain the current graph shape and compare against the configuration shape
        //    - if identical, skip — the wire is already correct
        //    - otherwise, disconnect the wire and treat it like a new connection (2)

        let toSymbolID   = try inputPort.asSymbolID()
        let existingWires = try database.wire.select(goingToNodeID: (try requireID()), toSymbolID: toSymbolID)

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
            var needsReconnection = true

            if let existingWire = existingWiresByName[wireName] {
                // Step 3 — wire already exists; check whether its current graph shape
                // still satisfies the expectation.  Compare parsed shapes structurally
                // (port-order-independent, bracket-format-independent) rather than as
                // raw strings to avoid spurious mismatches.
                let currentShapeNode  = try GraphShapeNode.buildFromWire(existingWire, database: database)
                let expectedShapeNode = try GraphShapeNode.parse(expectationString)

                do {
                    try currentShapeNode.expectTopologyMatch(expectedShapeNode)
                    // Topology matches — the existing wire already connects the correct
                    // node. Skip reconnection entirely: calling findOrCreate here risks
                    // picking up a zombie node that shares the same searchKey and then
                    // failing with attemptToCreateWireWithDuplicateName.
                    needsReconnection = false
                } catch {
                    // Topology changed (e.g. a formula was updated to add/remove a dependency).
                    // Before deleting, check whether the expected shape's searchKey already
                    // matches the node the wire connects to.  If so, expectTopologyMatch
                    // produced a false positive — reconnecting would reschedule this node every
                    // pass and cause an infinite loop.
                    if let match = try? expectedShapeNode.findMatchingNode(),
                       match.fromNodeID == existingWire.fromNodeID,
                       match.fromSymbolID == existingWire.fromSymbolID {
                        needsReconnection = false
                    } else {
//                        print("⚠️ topology mismatch on port '\(inputPort)' wire '\(wireName)' of node #\(id ?? -1): \(error)")
//                        print("   current:  \(currentShapeNode.asString(omitOutputPort: false).truncated(to: 3000))")
//                        print("   expected: \(expectedShapeNode.asString(omitOutputPort: false).truncated(to: 3000))")
                        _ = try existingWire.deleteWire(database: database)
                    }
                }
            }

            guard needsReconnection else { continue }

            // Wrap find-or-create and connectWire in a single transaction so that if
            // connectWire fails the newly-created upstream node is rolled back, preventing
            // it from being left as an orphaned zombie in the database.
            let wireNameSymbolID = try wireName.asSymbolID()
            try database.withTransaction {
                guard let (fromNode, fromSymbolID) = try findExistingOrCreateNodeMatchingExpectation(expectationString) else {
                    print("applyExpectationConfiguration: no node found matching expectation '\(expectationString)' for wire '\(wireName)' on input '\(inputPort)' of node #\(id ?? -1)")
                    return
                }
                // fromSymbolID is nil when the expectation string has no .outputPort suffix,
                // which is invalid for wiring — expectation strings must include a port.
                guard let fromSymbolID else {
                    print("applyExpectationConfiguration: expectation '\(expectationString)' has no output port — cannot wire")
                    return
                }
                try Wire.connectWire(database: database,
                                     fromNodeID: (try fromNode.requireID()),
                                     fromSymbolID: fromSymbolID,
                                     toNodeID: (try requireID()),
                                     toSymbolID: toSymbolID,
                                     name: wireNameSymbolID)
            }
        }
    }

    /// Parses `expectationString` into a `GraphShapeNode` and searches the live
    /// graph for a node whose type and recursive input wiring matches it,
    /// creating the required nodes and wires if none is found.
    /// Returns `(fromNodeID, fromSymbolID)` ready to pass to `connectWire`, or
    /// `nil` if the type name in the expectation is not registered in PolyFactory.
    private func findExistingOrCreateNodeMatchingExpectation(_ expectationString: String) throws -> (fromNode: Node, fromSymbolID: ObjectID?)? {
        let expectedShape = try GraphShapeNode.parse(expectationString)
        return try expectedShape.findOrCreateMatchingNode()
    }

    func buildErrorOutput(withError error: Error) -> ProcessOutput {
        var outputValues = [String: NodeValue]()

        switch error {
        case NodeError.inputValuePending:
            for outputPort in descriptor.outputPorts {
                outputValues[outputPort] = .noValue(reason: .pending)
            }

        default:
            for outputPort in descriptor.outputPorts {
                outputValues[outputPort] = .noValue(reason: .error(message: "\(error)"))
            }
        }


        // Reconstruct existing dynamic wire expectations from the live graph so
        // applyExpectationConfiguration's step 1 doesn't delete them on error.
        // A brand-new node that errors on first run has no wires yet, so the
        // dict is empty for it — which is also correct (nothing to preserve).

        var wireExpectations = [String: [String: String]]()

        for port in descriptor.dynamicInputPorts {
            // Already building an error result, so a further failure here just means this
            // port's expectations cannot be preserved — skip it rather than escalate.
            guard let toSymbolID = try? port.asSymbolID(),
                  let nodeID = try? requireID(),
                  let wires = try? database.wire.select(goingToNodeID: nodeID, toSymbolID: toSymbolID),
                  !wires.isEmpty else {
                continue
            }

            var portExpectations = [String: String]()

            for wire in wires {
                let wireName = wire.name.resolveSymbol()

                if let shapeNode = try? GraphShapeNode.buildFromWire(wire, database: database) {
                    portExpectations[wireName] = shapeNode.asString(omitOutputPort: false)
                }
            }

            if !portExpectations.isEmpty {
                wireExpectations[port] = portExpectations
            }
        }
        return .init(outputValues: outputValues, inputWireExpectations: wireExpectations)
    }

    fileprivate func hasInputPorts() -> Bool {
        !descriptor.staticInputPorts.isEmpty || !descriptor.dynamicInputPorts.isEmpty
    }
}

protocol MessageType: AnyObject, Codable, PolySerializable {
}

// MARK: - NodeError

public enum NodeError: Error {
    case nodeNotFound
    case onlyOneWireShouldBeConnectedToInput
    case inputValueInError
    case inputValuePending
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
        try (try toJSON()).intern()
    }
}
