//
//  WireManagement.swift
//  semel
//
//  Created by Jade Burton on 28.02.26.
//

import SemelNodeKit

/// Wiring refused. Sentences rather than case names, because the engine interns a thrown
/// error's text onto the failing node's output ports.
enum WireError: Error, CustomStringConvertible {
    /// Wire names are unique per (toNodeID, toSymbolID) — i.e. per input port on the target node.
    case attemptToCreateWireWithDuplicateName(_ name: String)
    case failedToDeleteWire
    /// Adding this wire would form a cycle in the dependency graph.
    case circularReference(fromNodeID: ObjectID, toNodeID: ObjectID)
    /// A static port wired after its node was made. Its wires are part of the node's
    /// identity, which is taken once, when the node is made from its spec (B-115).
    case staticPortWiredAfterCreation(typeName: String, portName: String)

    var description: String {
        switch self {
        case .attemptToCreateWireWithDuplicateName(let name):
            return "an input port already has a different wire named '\(name)'"
        case .failedToDeleteWire:
            return "a wire could not be disconnected"
        case .circularReference(let fromNodeID, let toNodeID):
            return "wiring node \(fromNodeID) into node \(toNodeID) would make the graph circular"
        case .staticPortWiredAfterCreation(let typeName, let portName):
            return "\(typeName)'s input '\(portName)' is wired when the node is made, from its spec, and cannot be wired afterwards"
        }
    }
}

// Wire management
extension Wire {

    /// Wires one of a node's dynamic ports: a wire the node demanded of itself.
    ///
    /// A static port is refused. Its wires are part of the node's identity, taken once when
    /// the node is made (B-115), so a static wire added afterwards leaves the node filed
    /// under the identity of what it was: a demand for that finds a node wired otherwise,
    /// and a node made later to that description carries the same identity and cannot be
    /// stored beside it (B-127). The applier wires a node's static ports as it makes it,
    /// through `connectWireAtCreation`.
    static func connectWire(database: DatabaseLayer,
                            fromNodeID: ObjectID,
                            fromSymbolID: ObjectID,
                            toNodeID: ObjectID,
                            toSymbolID: ObjectID,
                            name: ObjectID) throws {
        let toNode   = try database.node.select(nodeID: toNodeID).makeNode()
        let portName = toSymbolID.resolveSymbol()
        guard !toNode.descriptor.staticInputPorts.contains(portName) else {
            throw WireError.staticPortWiredAfterCreation(typeName: String(describing: type(of: toNode)), portName: portName)
        }
        try insertWire(database: database, fromNodeID: fromNodeID, fromSymbolID: fromSymbolID,
                       toNodeID: toNodeID, toSymbolID: toSymbolID, name: name)
    }

    /// Wires a static port of a node the applier is making, from the row its identity was
    /// taken of: the one moment a static port is wired.
    static func connectWireAtCreation(database: DatabaseLayer,
                                      fromNodeID: ObjectID,
                                      fromSymbolID: ObjectID,
                                      toNodeID: ObjectID,
                                      toSymbolID: ObjectID,
                                      name: ObjectID) throws {
        try insertWire(database: database, fromNodeID: fromNodeID, fromSymbolID: fromSymbolID,
                       toNodeID: toNodeID, toSymbolID: toSymbolID, name: name)
    }

    private static func insertWire(database: DatabaseLayer,
                                   fromNodeID: ObjectID,
                                   fromSymbolID: ObjectID,
                                   toNodeID: ObjectID,
                                   toSymbolID: ObjectID,
                                   name: ObjectID) throws {

        // The same wire, demanded again: connecting is idempotent. A wire between the same
        // ports under a *different* name is a different wire and is created alongside it.
        guard try database.wire.select(comingFromNodeID: fromNodeID,
                                       fromSymbolID: fromSymbolID,
                                       goingToNodeID: toNodeID,
                                       toSymbolID: toSymbolID,
                                       name: name) == nil else {
            return
        }

        if try wireExistsWithSameName(database: database,
                                      fromNodeID: fromNodeID,
                                      fromSymbolID: fromSymbolID,
                                      toNodeID: toNodeID,
                                      toSymbolID: toSymbolID,
                                      name: name) {
            throw WireError.attemptToCreateWireWithDuplicateName(name.resolveSymbol())
        }

        // Both ways in are called inside database.withTransaction (connectWire in
        // applySpecs, connectWireAtCreation in GraphSpecTableApplier.createNode), so
        // the insert, pendingDeletion clear, and writePending are all-or-nothing.

        if try wouldCreateCycle(database: database, fromNodeID: fromNodeID, toNodeID: toNodeID) {
            throw WireError.circularReference(fromNodeID: fromNodeID, toNodeID: toNodeID)
        }

        _ = try database.wire.insert(.init(fromNodeID: fromNodeID,
                                          fromSymbolID: fromSymbolID,
                                          toNodeID: toNodeID,
                                          toSymbolID: toSymbolID,
                                          name: name))

        // The source node has a new consumer — clear any pending-deletion mark. Part of the
        // all-or-nothing above: a mark that survives would let the collector delete a node
        // that just gained a consumer.
        try database.node.updatePendingDeletion(nodeID: fromNodeID, pendingDeletion: false)

        let toNode = try database.node.select(nodeID: toNodeID)
        try toNode.writePendingToAllOutputsOfNode()
        BuildEngine.shared?.settleRecorder.noteWake(consumerNodeID: toNodeID,
                                                    wire: Wire(fromNodeID: fromNodeID, fromSymbolID: fromSymbolID,
                                                               toNodeID: toNodeID, toSymbolID: toSymbolID, name: name),
                                                    change: .connected)
        try toNode.setScheduled(true)
    }

    /// Returns `true` if adding `fromNodeID → toNodeID` would create a cycle —
    /// i.e. `toNodeID` can already reach `fromNodeID` through existing wires.
    /// Uses BFS over outgoing wires (data-flow direction).
    private static func wouldCreateCycle(database: DatabaseLayer,
                                         fromNodeID: ObjectID,
                                         toNodeID: ObjectID) throws -> Bool {
        var visited = Set<ObjectID>()
        var queue = [toNodeID]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current == fromNodeID { return true }
            guard !visited.contains(current) else { continue }
            visited.insert(current)
            for wire in try database.wire.select(comingFromNodeID: current) {
                queue.append(wire.toNodeID)
            }
        }
        return false
    }

    /// Returns `true` if a wire going to `(toNodeID, toSymbolID)` already uses
    /// `name`, but comes from a *different* source than `(fromNodeID, fromSymbolID)`.
    /// A wire with the same name AND the same source is a harmless duplicate — the
    /// caller's earlier guard will catch and skip it.
    ///
    /// The name is looked up, not searched for among the wires at the port: a port takes a
    /// fan as wide as the graph demands, and reading that fan to guard one connection makes
    /// wiring a fan of N cost O(N²) row reads (B-106).
    static func wireExistsWithSameName(database: DatabaseLayer,
                                       fromNodeID: ObjectID,
                                       fromSymbolID: ObjectID,
                                       toNodeID: ObjectID,
                                       toSymbolID: ObjectID,
                                       name: ObjectID) throws -> Bool {

        try database.wire.select(goingToNodeID: toNodeID, toSymbolID: toSymbolID, name: name)
            .contains { $0.fromNodeID != fromNodeID || $0.fromSymbolID != fromSymbolID }
    }

    func deleteWire(database: DatabaseLayer) throws {

        guard try database.wire.delete(comingFromNodeID: fromNodeID,
                                       fromSymbolID: fromSymbolID,
                                       goingToNodeID: toNodeID,
                                       toSymbolID: toSymbolID,
                                       name: name) else {
            throw WireError.failedToDeleteWire
        }

        let fromNode = try database.node.select(nodeID: fromNodeID).makeNode()

        let noOutputWires = try fromNode.hasNoOutputWires()
        let deletable     = try fromNode.canBeDeleted()

        if noOutputWires && deletable {
            // fromNode has no remaining consumers — mark it for deferred deletion.
            // Actual cascade and removal happen at idle time in processPendingDeletions(),
            // keeping all structural graph mutations out of the processing path.
            try database.node.updatePendingDeletion(nodeID: fromNodeID, pendingDeletion: true)
        } else {
            // fromNode still has other consumers or must be kept alive.
            // Notify the consumer that one of its inputs changed so it can re-evaluate.
            let toNode = try database.node.select(nodeID: toNodeID)
            try toNode.writePendingToAllOutputsOfNode()
            BuildEngine.shared?.settleRecorder.noteWake(consumerNodeID: toNodeID, wire: self, change: .disconnected)
            try toNode.setScheduled(true)
        }
    }
}
