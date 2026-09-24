//
//  Node+Graph.swift
//  semel
//
//  The engine's side of the node protocols declared in SemelNodeKit: reading input ports,
//  deciding whether a node is ready, applying wire specs, writing outputs and
//  notifying parents. All of it touches the graph, which is why it is here and not in the
//  node-authoring API.
//

import Foundation
import SemelDatabaseModels
import SemelNodeKit

extension Node {

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
                // GraphSpecApplier.createNode() validates this at creation time (requiredPortUnwired),
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

    /// Runs `process` and turns any thrown error into an error result on the node's
    /// output ports — except an unrecoverable one, which stops the build.
    /// Internal rather than private so a test can drive this boundary directly.
    func processWithCatch(input: ProcessInput) -> ProcessOutput {
        do {
            Debug.log("\(type(of: self)), nodeID \(thisNode.id ?? -1)")
            return try process(input: input)
        } catch {
            // Filing a full disk as "node 47 failed" hides the real problem, and every
            // node after this one would fail the same way.
            FatalErrors.check(error)
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

        // The material once, and the key from it: the entry this saves is keyed on exactly
        // what it stores beside it.
        let keyMaterial = try? buildCacheKeyMaterial(input: input)
        let cacheKey    = keyMaterial.flatMap { try? $0.cacheKey() }
        var didWriteCachedOutput = false

        if let cachedOutput = try? loadCachedOutputs(cacheKey: cacheKey) {
            do {
                try writeToOutputs(output: cachedOutput)
                didWriteCachedOutput = true
            } catch {
                // Cached output is stale or the graph topology changed — fall
                // through and reprocess so the node does not stay stuck.
                Debug.warn("writeToOutputs failed for cached output, reprocessing: \(error)")
            }
        }

        if !didWriteCachedOutput {
            let startTime = Date.now
            let output = processWithCatch(input: input)
            try writeToOutputs(output: output)
            // Failing to save a cache entry must not fail a build — unless the failure is
            // the machine's, which no later node will survive either.
            do {
                try saveCacheForAllInputsAndOutputs(keyMaterial: keyMaterial,
                                                    processingDuration: Date.now.timeIntervalSince(startTime),
                                                    output: output)
            } catch {
                FatalErrors.check(error)
            }
        }
    }

    /// Phase 1 of two-phase parallel processing: reads inputs and computes the
    /// output without making any graph mutations.  Safe to call concurrently with
    /// other nodes.  Returns nil if this node is not ready to process (no input
    /// ports, inputs pending, required wires missing, etc.).
    func tryComputeOutput() -> (output: ProcessOutput, keyMaterial: CacheKeyMaterial?,
                                fromCache: Bool, computeStart: Date)? {
        guard hasInputPorts() else {
            return nil
        }
        // A node that cannot even assemble its input is not "not ready", it is broken —
        // and silently returning nil left it scheduled forever with nothing said. Say why.
        let input: ProcessInput
        do {
            input = try buildProcessInput()
        } catch {
            Debug.warn("\(type(of: self)) nodeID \(thisNode.id ?? -1) cannot read its inputs: \(error)")
            return nil
        }
        do {
            guard try allInputsAreSatisfied(input: input) else {
                let pendingPorts = input.inputValues.filter { $0.value.values.contains { $0.isPending } }.keys.sorted()
                Debug.log("\(type(of: self)) nodeID \(thisNode.id ?? -1) not ready: pending on \(pendingPorts)")
                return nil
            }
        } catch {
            Debug.warn("\(type(of: self)) nodeID \(thisNode.id ?? -1) has an inconsistent input: \(error)")
            return nil
        }

        let keyMaterial = try? buildCacheKeyMaterial(input: input)
        let cacheKey    = keyMaterial.flatMap { try? $0.cacheKey() }

        if let cached = try? loadCachedOutputs(cacheKey: cacheKey) {
            return (cached, keyMaterial, true, .now)
        }

        let computeStart = Date.now
        return (processWithCatch(input: input), keyMaterial, false, computeStart)
    }
}

extension Node {
    var parentNode: Node? {
        get throws {
            if let parentNodeID = thisNode.parentNodeID {
                return try database.node.select(nodeID: parentNodeID).makeNode()
            }
            return nil
        }
    }

    func notifyParentThisChildAdded() throws {
        try parentNode?.onChildAdded(nodeID: (try thisNode.requireID()))
    }

    func notifyParentOfChildContentChange() throws {
        try parentNode?.onChildContentChanged(nodeID: (try thisNode.requireID()), name: thisNode.name!)
    }

    func notifyParentOfChildDeletion() throws {
        // A cascade deletes a folder before its children, so the parent may already be
        // gone by the time a child goes: nothing to notify, and not a failure. (`parentNode`
        // treats a missing parent as an error, which is right everywhere else.)
        guard let parentNodeID = thisNode.parentNodeID,
              let parent = try database.node.find(nodeID: parentNodeID) else {
            return
        }
        try parent.makeNode().onChildDeleted(nodeID: try thisNode.requireID())
    }

    func delete() throws {
        let safeToDelete = try hasNoOutputWires() && hasNoInputWires()
        assert(safeToDelete)

        _ = try database.node.delete(nodeID: (try requireID()))
        try notifyParentOfChildDeletion()
    }

    var database: DatabaseLayer {
        DatabaseLayer.shared
    }

    func hasNoOutputWires() throws -> Bool {
        try database.wire.select(comingFromNodeID: (try requireID())).isEmpty
    }

    func hasNoInputWires() throws -> Bool {
        try database.wire.select(goingToNodeID: (try requireID())).isEmpty
    }

    func writeToOutputs(output: ProcessOutput) throws {

        let numberOfOutputPorts = try database.outputPort.selectAll(nodeID: (try requireID())).count

        if numberOfOutputPorts != output.outputValues.count {
            Debug.warn("mismatch between \(output.outputValues.count) output values and \(numberOfOutputPorts) output ports for node \(thisNode)")
        }

        if numberOfOutputPorts != descriptor.outputPorts.count {
            Debug.warn("descriptor declares \(descriptor.outputPorts.count) outputs but the node has \(numberOfOutputPorts) output ports: \(thisNode)")
        }

        for (outputPort, outputValue) in output.outputValues {
            if outputValue.isPending {
                Debug.warn("output left pending for node \(thisNode): outputPort \(outputPort)")
            }
            try thisNode.writeToOutputPort(outputPort, value: outputValue)
        }

        do {
            for (inputPort, wireSpecs) in output.inputWireSpecs {
                try applySpecs(inputPort: inputPort, wireSpecs: wireSpecs)
            }
        } catch {
            Debug.warn("applySpecs failed: \(error)")

            for outputPort in descriptor.outputPorts {
                try thisNode.writeToOutputPort(outputPort, value: .noValue(reason: .error(messageDataObjectHash: "\(error)".intern())))
            }
            throw error
        }
    }

    private func applySpecs(inputPort: String, wireSpecs: [String: String]) throws {
        // 1. remove any wires that exist but are not in the new configuration (by name)
        // 2. add any wires that are in the new configuration but do not exist yet (by name)
        // 3. update spec on wires that exist in both old and new configuration (by name)
        //    - obtain the current graph spec and compare against the configured spec
        //    - if identical, skip — the wire is already correct
        //    - otherwise, disconnect the wire and treat it like a new connection (2)

        let toSymbolID   = inputPort.asSymbolID()
        let existingWires = try database.wire.select(goingToNodeID: (try requireID()), toSymbolID: toSymbolID)

        // Build a lookup from wire name → existing Wire for steps 2 & 3.
        let existingWiresByName: [String: Wire] = Dictionary(
            uniqueKeysWithValues: existingWires.map { ($0.name.resolveSymbol(), $0) }
        )

        // Step 1 — delete wires whose name is absent from the new configuration.
        for (wireName, existingWire) in existingWiresByName.sorted(by: { $0.key < $1.key }) {
            if wireSpecs[wireName] == nil {
                _ = try existingWire.deleteWire(database: database)
            }
        }

        // Steps 2 & 3 — iterate over the desired configuration. Sorted: the order wires are
        // created in decides the order they are read back in, and a dictionary's is seeded
        // per process (B-04).
        for (wireName, specString) in wireSpecs.sorted(by: { $0.key < $1.key }) {
            var needsReconnection = true

            if let existingWire = existingWiresByName[wireName] {
                // Step 3 — wire already exists; check whether its current graph spec
                // still satisfies the spec.  Compare parsed specs structurally
                // (port-order-independent, bracket-format-independent) rather than as
                // raw strings to avoid spurious mismatches.
                let currentShapeNode  = try GraphSpecNode.buildFromWire(existingWire, database: database)
                let expectedShapeNode = try GraphSpecNode.parse(specString)

                do {
                    try currentShapeNode.expectTopologyMatch(expectedShapeNode)
                    // Topology matches — the existing wire already connects the correct
                    // node. Skip reconnection entirely: calling findOrCreate here risks
                    // picking up a zombie node that shares the same graphSpec and then
                    // failing with attemptToCreateWireWithDuplicateName.
                    needsReconnection = false
                } catch {
                    // Topology changed (e.g. a formula was updated to add/remove a dependency).
                    // Before deleting, check whether the demanded spec's graphSpec already
                    // matches the node the wire connects to.  If so, expectTopologyMatch
                    // produced a false positive — reconnecting would reschedule this node every
                    // pass and cause an infinite loop.
                    if let match = try? expectedShapeNode.findMatchingNode(),
                       match.fromNodeID == existingWire.fromNodeID,
                       match.fromSymbolID == existingWire.fromSymbolID {
                        needsReconnection = false
                    } else {
                        _ = try existingWire.deleteWire(database: database)
                    }
                }
            }

            guard needsReconnection else { continue }

            // Wrap find-or-create and connectWire in a single transaction so that if
            // connectWire fails the newly-created upstream node is rolled back, preventing
            // it from being left as an orphaned zombie in the database.
            let wireNameSymbolID = wireName.asSymbolID()
            try database.withTransaction {
                guard let (fromNode, fromSymbolID) = try findExistingOrCreateNodeMatchingSpec(specString) else {
                    Debug.warn("no node matches spec '\(specString)' for wire '\(wireName)' on input '\(inputPort)' of node #\(thisNode.id ?? -1)")
                    return
                }
                // fromSymbolID is nil when the spec string has no .outputPort suffix,
                // which is invalid for wiring — spec strings must include a port.
                guard let fromSymbolID else {
                    Debug.warn("spec '\(specString)' has no output port — cannot wire")
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

    /// Parses `specString` into a `GraphSpecNode` and searches the live
    /// graph for a node whose type and recursive input wiring matches it,
    /// creating the required nodes and wires if none is found.
    /// Returns `(fromNodeID, fromSymbolID)` ready to pass to `connectWire`, or
    /// `nil` if the type name in the spec is not registered in TypeRegistry.
    private func findExistingOrCreateNodeMatchingSpec(_ specString: String) throws -> (fromNode: NodeRecord, fromSymbolID: ObjectID?)? {
        try GraphSpecNode.parse(specString).findOrCreateMatchingNode()
    }

    /// The output for a thrown error: the reason it puts on every port, decided here and
    /// nowhere else.
    ///
    /// An error that stopped this node without being its own failure — an input pending, an
    /// input in error, an input that has never been produced — is a state, and each has a
    /// case of its own so that nothing downstream reads a sentence to tell them apart.
    /// `NodeError.publishedState` is the table; the error is translated on the way to the
    /// port and never interned as text.
    func buildErrorOutput(withError error: Error) -> ProcessOutput {
        if let state = (error as? NodeError)?.publishedState {
            return buildOutput(reason: state)
        }

        let message = reportedMessage(for: error)
        return buildOutput(reason: .error(messageDataObjectHash: (try? message.intern()) ?? ""))
    }

    /// One reason on every output port, with the dynamic wire specs the graph already holds
    /// preserved.
    func buildOutput(reason: NoValueReason) -> ProcessOutput {
        var outputValues = [String: NodeValue]()

        for outputPort in descriptor.outputPorts {
            outputValues[outputPort] = .noValue(reason: reason)
        }

        // Reconstruct existing dynamic wire specs from the live graph so
        // applySpecs's step 1 doesn't delete them when the node publishes no values.
        // A brand-new node has no wires yet, so the dict is empty for it — which is also
        // correct (nothing to preserve).

        var wireSpecs = [String: [String: String]]()

        for port in descriptor.dynamicInputPorts {
            // Already building a result that publishes nothing, so a further failure here
            // just means this port's specs cannot be preserved — skip it rather than
            // escalate. Unless it is the machine failing, which the fatal handler hears
            // about either way.
            let toSymbolID = port.asSymbolID()
            guard let nodeID = try? requireID(),
                  let wires = FatalErrors.attempt({
                      try database.wire.select(goingToNodeID: nodeID, toSymbolID: toSymbolID)
                  }),
                  !wires.isEmpty else {
                continue
            }

            var portSpecs = [String: String]()

            for wire in wires {
                let wireName = wire.name.resolveSymbol()

                if let shapeNode = try? GraphSpecNode.buildFromWire(wire, database: database) {
                    portSpecs[wireName] = shapeNode.asString(omitOutputPort: false)
                }
            }

            if !portSpecs.isEmpty {
                wireSpecs[port] = portSpecs
            }
        }
        return .init(outputValues: outputValues, inputWireSpecs: wireSpecs)
    }

    /// A thrown error's text for a node's output ports. `SemelNodeKit` cannot name `reset`
    /// — it does not know the engine has one — so an unregistered kind gets its remedy
    /// appended here, where the engine renders the error rather than where it is thrown.
    private func reportedMessage(for error: Error) -> String {
        guard case TypeRegistryError.unknownKind = error else {
            return "\(error)"
        }
        return "\(error): the type is not linked into this semelserv, or the graph predates " +
               "its removal. reset discards the derived state that is stuck."
    }

    fileprivate func hasInputPorts() -> Bool {
        !descriptor.staticInputPorts.isEmpty || !descriptor.dynamicInputPorts.isEmpty
    }
}

protocol MessageType: AnyObject, Codable, PolySerializable {
}

// MARK: - NodeError

extension Node {
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
