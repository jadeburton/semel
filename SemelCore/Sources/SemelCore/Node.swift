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
                throw NodeError.inputPortMissing(port: inputPort)
            }

            guard !values.isEmpty else {
                // GraphSpecTableApplier.createNode() validates this at creation time (requiredPortUnwired),
                // so reaching here means a wire was removed after the node was built — a real integrity error.
                throw NodeError.requiredInputPortUnwired(port: inputPort)
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
            return buildErrorOutput(withError: error, input: input)
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
            let output  = processWithCatch(input: input)
            let applied = try writeToOutputs(output: output)
            // Failing to save a cache entry must not fail a build — unless the failure is
            // the machine's, which no later node will survive either.
            do {
                try saveCacheForAllInputsAndOutputs(keyMaterial: keyMaterial,
                                                    processingDuration: Date.now.timeIntervalSince(startTime),
                                                    output: applied)
            } catch {
                FatalErrors.check(error)
            }
        }
    }

    /// Phase 1 of two-phase parallel processing: reads inputs and computes the
    /// output without making any graph mutations.  Safe to call concurrently with
    /// other nodes.  Returns nil if this node is not ready to process (no input
    /// ports, inputs pending, required wires missing, etc.).
    func tryComputeOutput() -> (output: ComputedOutput, keyMaterial: CacheKeyMaterial?, computeStart: Date)? {
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
            return (.cached(cached), keyMaterial, .now)
        }

        let computeStart = Date.now
        return (.processed(processWithCatch(input: input)), keyMaterial, computeStart)
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
        try parentNode?.onChildContentChanged(nodeID: (try thisNode.requireID()), name: try thisNode.requireName())
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

    /// Writes a run's output: its values on the ports, and its demands wired.
    ///
    /// The demands are folded into a table — each node hashed once, children first — and
    /// applied from it exactly as a hit's stored table is, so there is one applier. The
    /// applied output is handed back for the cache entry to store, which is the table it
    /// would otherwise fold a second time.
    @discardableResult
    func writeToOutputs(output: ProcessOutput) throws -> AppliedOutput {
        try writeOutputValues(output.outputValues)
        return try failingOutputsOnThrow {
            let applied = try AppliedOutput(folding: output)
            try applySpecTable(applied.specTable)
            return applied
        }
    }

    /// Writes an output whose demands are a table already — a cache hit's.
    func writeToOutputs(output: AppliedOutput) throws {
        try writeOutputValues(output.outputValues)
        try failingOutputsOnThrow {
            try applySpecTable(output.specTable)
        }
    }

    private func writeOutputValues(_ outputValues: [String: NodeValue]) throws {
        let numberOfOutputPorts = try database.outputPort.selectAll(nodeID: (try requireID())).count

        if numberOfOutputPorts != outputValues.count {
            Debug.warn("mismatch between \(outputValues.count) output values and \(numberOfOutputPorts) output ports for node \(thisNode)")
        }

        if numberOfOutputPorts != descriptor.outputPorts.count {
            Debug.warn("descriptor declares \(descriptor.outputPorts.count) outputs but the node has \(numberOfOutputPorts) output ports: \(thisNode)")
        }

        for (outputPort, outputValue) in outputValues {
            if outputValue.isPending {
                Debug.warn("output left pending for node \(thisNode): outputPort \(outputPort)")
            }
            try thisNode.writeToOutputPort(outputPort, value: outputValue)
        }
    }

    /// A demand that cannot be applied fails the node: its error on every output port, in
    /// place of the values just written, and thrown on to the caller — a hit's caller
    /// reprocesses.
    private func failingOutputsOnThrow<Result>(_ work: () throws -> Result) throws -> Result {
        do {
            return try work()
        } catch {
            Debug.warn("applySpecs failed: \(error)")

            let failure = try ErrorDocument.thrown(error, subject: errorSubject(input: try? buildProcessInput())).published()
            for outputPort in descriptor.outputPorts {
                try thisNode.writeToOutputPort(outputPort, value: failure)
            }
            throw error
        }
    }

    /// Every port a table's demands name, in port order, through one applier: a node the
    /// demands of two ports share is found or made once.
    private func applySpecTable(_ specTable: GraphSpecTable) throws {
        var applier = GraphSpecTableApplier(table: specTable, database: database)
        for (inputPort, references) in specTable.inputWireSpecs.sorted(by: { $0.key < $1.key }) {
            try applySpecs(inputPort: inputPort, references: references, applier: &applier)
        }
    }

    private func applySpecs(inputPort: String,
                            references: [String: GraphSpecTable.Reference],
                            applier: inout GraphSpecTableApplier) throws {
        // 1. remove any wires that exist but are not in the new configuration (by name)
        // 2. add any wires that are in the new configuration but do not exist yet (by name)
        // 3. keep a wire that exists in both when it already comes from the node and port
        //    demanded; otherwise disconnect it and treat it like a new connection (2)

        let toSymbolID   = inputPort.asSymbolID()
        let existingWires = try database.wire.select(goingToNodeID: (try requireID()), toSymbolID: toSymbolID)

        // Build a lookup from wire name → existing Wire for steps 2 & 3.
        let existingWiresByName: [String: Wire] = Dictionary(
            uniqueKeysWithValues: existingWires.map { ($0.name.resolveSymbol(), $0) }
        )

        // Step 1 — delete wires whose name is absent from the new configuration.
        for (wireName, existingWire) in existingWiresByName.sorted(by: { $0.key < $1.key }) {
            if references[wireName] == nil {
                _ = try existingWire.deleteWire(database: database)
            }
        }

        // Steps 2 & 3 — iterate over the desired configuration. Sorted: the order wires are
        // created in decides the order they are read back in, and a dictionary's is seeded
        // per process (B-04).
        for (wireName, reference) in references.sorted(by: { $0.key < $1.key }) {
            var needsReconnection = true

            if let existingWire = existingWiresByName[wireName] {
                // Step 3 — the wire exists; it is right when the node it comes from is the
                // one demanded and the port is the one named. The reference carries the
                // demanded node's identity and the wire's source carries its own, so this
                // compares two stored values (B-115, B-121): nothing is hashed.
                let source = try database.node.select(nodeID: existingWire.fromNodeID)
                if source.identity == reference.identity,
                   existingWire.fromSymbolID == reference.outputPort?.asSymbolID() {
                    needsReconnection = false
                } else {
                    _ = try existingWire.deleteWire(database: database)
                }
            }

            guard needsReconnection else { continue }

            // Wrap find-or-create and connectWire in a single transaction so that if
            // connectWire fails the newly-created upstream node is rolled back, preventing
            // it from being left as an orphaned zombie in the database.
            let wireNameSymbolID = wireName.asSymbolID()
            try database.withTransaction {
                let fromNode = try applier.node(identity: reference.identity)
                // nil when the demand names no output port, which is invalid for wiring — a
                // demanded node is a wire's source, and a source is read at a port.
                guard let fromSymbolID = reference.outputPort?.asSymbolID() else {
                    let typeName = (try? applier.table.row(identity: reference.identity))?.typeName ?? "node"
                    Debug.warn("a demanded \(typeName) \(NodeIdentity.shown(reference.identity))… names no output port — cannot wire")
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

    /// The output for a thrown error: the reason it puts on every port, decided here and
    /// nowhere else.
    ///
    /// An error that stopped this node without being its own failure — an input pending, an
    /// input in error, an input that has never been produced — is a state, and each has a
    /// case of its own so that nothing downstream reads a document to tell them apart.
    /// `NodeError.publishedState` is the table. Anything else is the node's own failure,
    /// published as the document its condition names, under what the node says it belongs
    /// to.
    func buildErrorOutput(withError error: Error, input: ProcessInput?) -> ProcessOutput {
        if let state = (error as? NodeError)?.publishedState {
            return buildOutput(reason: state)
        }

        let document = ErrorDocument.thrown(error, subject: errorSubject(input: input))
        // Interning writes the store, and a store that cannot be written stops the build
        // through the fatal handler wherever it is met; the empty hash is what a port holds
        // for an error with no document, which a report says as one it cannot read.
        return buildOutput(reason: (try? document.asReason()) ?? .error(documentHash: ""))
    }

    /// One reason on every output port, and the dynamic wires the graph already holds left
    /// as they are: `writeToOutputs` applies specs only to the ports an output names, so an
    /// output that names none keeps every wire — which is what a node that could not run
    /// wants, and needs no description of those wires to say.
    func buildOutput(reason: NoValueReason) -> ProcessOutput {
        var outputValues = [String: NodeValue]()

        for outputPort in descriptor.outputPorts {
            outputValues[outputPort] = .noValue(reason: reason)
        }
        return .init(outputValues: outputValues, inputWireSpecs: [:])
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
