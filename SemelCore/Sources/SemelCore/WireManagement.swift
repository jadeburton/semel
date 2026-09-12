//
//  WireManagement.swift
//  semel
//
//  Created by Jade Burton on 28.02.26.
//

import SemelNodeKit

enum WireError: Error {
    /// Wire names are unique per (toNodeID, toSymbolID) — i.e. per input port on the target node.
    case attemptToCreateWireWithDuplicateName(_ name: String)
    case failedToDeleteWire
    /// Adding this wire would form a cycle in the dependency graph.
    case circularReference(fromNodeID: ObjectID, toNodeID: ObjectID)
}

// Wire management
extension Wire {

    static func connectWire(database: DatabaseLayer,
                            fromNodeID: ObjectID,
                            fromSymbolID: ObjectID,
                            toNodeID: ObjectID,
                            toSymbolID: ObjectID,
                            name: ObjectID) throws {

        guard try database.wire.select(comingFromNodeID: fromNodeID,
                                       fromSymbolID: fromSymbolID,
                                       goingToNodeID: toNodeID,
                                       toSymbolID: toSymbolID).isEmpty else {
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

        // connectWire is always called inside database.withTransaction (in
        // applySpecs and GraphSpecApplier.createNode), so
        // the insert, pendingDeletion clear, and writePending are all-or-nothing.

        if try wouldCreateCycle(database: database, fromNodeID: fromNodeID, toNodeID: toNodeID) {
            throw WireError.circularReference(fromNodeID: fromNodeID, toNodeID: toNodeID)
        }

        _ = try database.wire.insert(.init(fromNodeID: fromNodeID,
                                          fromSymbolID: fromSymbolID,
                                          toNodeID: toNodeID,
                                          toSymbolID: toSymbolID,
                                          name: name))

        // The source node has a new consumer — clear any pending-deletion mark.
        try? database.node.updatePendingDeletion(nodeID: fromNodeID, pendingDeletion: false)

        let toNode = try database.node.select(nodeID: toNodeID)
        try toNode.writePendingToAllOutputsOfNode()
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
    static func wireExistsWithSameName(database: DatabaseLayer,
                                       fromNodeID: ObjectID,
                                       fromSymbolID: ObjectID,
                                       toNodeID: ObjectID,
                                       toSymbolID: ObjectID,
                                       name: ObjectID) throws -> Bool {

        try database.wire.select(goingToNodeID: toNodeID, toSymbolID: toSymbolID)
            .contains { $0.name == name && ($0.fromNodeID != fromNodeID || $0.fromSymbolID != fromSymbolID) }
    }

    func deleteWire(database: DatabaseLayer) throws {

        guard try database.wire.delete(comingFromNodeID: fromNodeID,
                                       fromSymbolID: fromSymbolID,
                                       goingToNodeID: toNodeID,
                                       toSymbolID: toSymbolID) else {
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
            try toNode.setScheduled(true)
        }
    }
}
