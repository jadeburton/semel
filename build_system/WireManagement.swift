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

    static func connectWire(fromNodeID: ObjectID,
                            fromSymbolID: ObjectID,
                            toNodeID: ObjectID,
                            toSymbolID: ObjectID,
                            name: ObjectID) throws {

        guard try DatabaseLayer.shared.selectWires(comingFromNodeID: fromNodeID,
                                                   fromSymbolID: fromSymbolID,
                                                   goingToNodeID: toNodeID,
                                                   toSymbolID: toSymbolID).isEmpty else {
            return
        }

        if try wireExistsWithSameName(fromNodeID: fromNodeID,
                                       fromSymbolID: fromSymbolID,
                                       toNodeID: toNodeID,
                                       toSymbolID: toSymbolID,
                                       name: name) {
            throw WireError.attemptToCreateWireWithDuplicateName(name.resolveSymbol())
        }

        // TODO: transactional
        // TODO: if there is a circular reference, block the creation of the Wire
        _ = try DatabaseLayer.shared.insertWire(.init(fromNodeID: fromNodeID,
                                                      fromSymbolID: fromSymbolID,
                                                      toNodeID: toNodeID,
                                                      toSymbolID: toSymbolID,
                                                      name: name))

        var toNode = try toNodeID.loadNode()
        try toNode.writePendingToAllOutputsOfNode()
        try toNode.setScheduledAndSave(true)
    }

    /// Returns `true` if a wire going to `(toNodeID, toSymbolID)` already uses
    /// `name`, but comes from a *different* source than `(fromNodeID, fromSymbolID)`.
    /// A wire with the same name AND the same source is a harmless duplicate — the
    /// caller's earlier guard will catch and skip it.
    static func wireExistsWithSameName(fromNodeID: ObjectID,
                                       fromSymbolID: ObjectID,
                                       toNodeID: ObjectID,
                                       toSymbolID: ObjectID,
                                       name: ObjectID) throws -> Bool {

        try DatabaseLayer.shared.selectWires(goingToNodeID: toNodeID, toSymbolID: toSymbolID)
            .contains { $0.name == name && ($0.fromNodeID != fromNodeID || $0.fromSymbolID != fromSymbolID) }
    }

    func deleteWire() throws {

        guard try DatabaseLayer.shared.deleteWire(comingFromNodeID: fromNodeID,
                                                         fromSymbolID: fromSymbolID,
                                                         goingToNodeID: toNodeID,
                                                  toSymbolID: toSymbolID) else {
            throw WireError.failedToDeleteWire
        }

        // We deleted an input to another Node; it should update.
        var toNode = try toNodeID.loadNode()
        try toNode.writePendingToAllOutputsOfNode()
        try toNode.setScheduledAndSave(true)

        // After deleting the Wire, check the origin (outputting) Node. If it now has no output wires at all, and if it is deletable,
        // delete it.

        let fromNode = try fromNodeID.loadNode()
        let fromNodeFunction = try fromNode.nodeFunction()

        // Now clean up any input wires to the just-deleted Node.

        for inputWire in try DatabaseLayer.shared.selectWires(goingToNodeID: fromNodeID) {
            _ = try inputWire.deleteWire()
        }

        if try fromNodeFunction.hasNoOutputWires(thisNode: fromNode) && fromNodeFunction.canBeDeleted(thisNode: fromNode) {
            // Safe to delete.
            _ = try DatabaseLayer.shared.deleteNode(nodeID: fromNodeID)
            // TODO: notify parent Folder, if there is one
        }
    }
}
