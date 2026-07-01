//
//  WireManagement.swift
//  build_system
//
//  Created by Jade Burton on 28.02.26.
//

enum WireError: Error {
    case attemptToCreateWireWithDuplicateName(_ name: String)
    case failedToDeleteWire
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

        // TODO: transactional
        // TODO: if there is a circular reference, block the creation of the Wire
        _ = try database.wire.insert(.init(fromNodeID: fromNodeID,
                                          fromSymbolID: fromSymbolID,
                                          toNodeID: toNodeID,
                                          toSymbolID: toSymbolID,
                                          name: name))

        let toNode = try database.node.select(nodeID: toNodeID)
        try toNode.writePendingToAllOutputsOfNode()
        try toNode.setScheduled(true)
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

    // TODO: find home
    func deleteWire(database: DatabaseLayer) throws {

        guard try database.wire.delete(comingFromNodeID: fromNodeID,
                                       fromSymbolID: fromSymbolID,
                                       goingToNodeID: toNodeID,
                                       toSymbolID: toSymbolID) else {
            throw WireError.failedToDeleteWire
        }

        // We deleted an input to another Node; it should update.
        let toNode = try database.node.select(nodeID: toNodeID)
        try toNode.writePendingToAllOutputsOfNode()
        try toNode.setScheduled(true)

        // After deleting the Wire, check the origin (outputting) Node. If it now has no output wires at all, and if it is deletable,
        // delete it.

        let fromNode = try database.node.select(nodeID: fromNodeID)
        let fromNodeFunction = try fromNode.nodeFunction()

        // Now clean up any input wires to the just-deleted Node.

        for inputWire in try database.wire.select(goingToNodeID: fromNodeID) {
            _ = try inputWire.deleteWire(database: database)
        }

        if try fromNodeFunction.hasNoOutputWires() && fromNodeFunction.canBeDeleted() {
            // Safe to delete.
            try fromNodeFunction.delete()
        }
    }
}
