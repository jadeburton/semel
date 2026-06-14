//
//  WireManagement.swift
//  build_system
//
//  Created by Jade Burton on 28.02.26.
//

// Wire management
extension ProcessingCycle {

    func connectWire(fromNodeID: ObjectID,
                     fromSymbolID: ObjectID,
                     toNodeID: ObjectID,
                     toSymbolID: ObjectID,
                     name: ObjectID) throws {

        guard try database.selectWires(comingFromNodeID: fromNodeID,
                                       fromSymbolID: fromSymbolID,
                                       goingToNodeID: toNodeID,
                                       toSymbolID: toSymbolID).isEmpty else {
            return
        }

        // TODO: transactional
        // TODO: if there is a circular reference, block the creation of the Wire
        _ = try database.insertWire(.init(fromNodeID: fromNodeID,
                                          fromSymbolID: fromSymbolID,
                                          toNodeID: toNodeID,
                                          toSymbolID: toSymbolID,
                                          name: name))

        wiresModified = true

        try writePendingToAllOutputsOfNode(nodeID: toNodeID)

        try scheduleNode(toNodeID)
    }
/*
    func connectWire(fromNode: NodeFunction,
                     fromPort: String,
                     toNode: NodeFunction,
                     toPort: String) throws {

        try connectWire(fromNodeID: fromNode.nodeID,
                        fromSymbolID: Symbol. fromPort.asSymbolID(database: database),
                        toNodeID: toNode.nodeID,
                        toSymbolID: toPort.asSymbolID(database: database))
    }

    func deleteWire(fromNodeID: ObjectID,
                    fromSymbolID: ObjectID,
                    toNodeID: ObjectID,
                    toSymbolID: ObjectID) throws -> Bool {

        try deleteWire(fromNodeID: fromNode.nodeID,
                       fromSymbolID: fromPort.asSymbolID(database: database),
                       toNodeID: toNode.nodeID,
                       toSymbolID: toPort.asSymbolID(database: database))
    }
*/
    func findNodeConnectedToNodeViaInputWire(_ toNode: NodeFunction, toInputSymbold inputSymbol: String) throws -> [any NodeFunction] {

        return try database.selectWires(goingToNodeID: toNode.nodeID,
                                        toSymbolID: inputSymbol.asSymbolID()).map { wire in
            try nodePoly(nodeID: wire.fromNodeID)!
        }
    }

    func deleteWire(fromNodeID: ObjectID,
                    fromSymbolID: ObjectID,
                    toNodeID: ObjectID,
                    toSymbolID: ObjectID) throws -> Bool {
        let wires = try database.selectWires(comingFromNodeID: fromNodeID,
                                             fromSymbolID: fromSymbolID,
                                             goingToNodeID: toNodeID,
                                             toSymbolID: toSymbolID)
        guard let wire = wires.first else {
            return false
        }

        return try deleteWire(wire)
    }

    func deleteWire(_ wire: Wire) throws -> Bool {

        let result = try database.deleteWire(comingFromNodeID: wire.fromNodeID,
                                             fromSymbolID: wire.fromSymbolID,
                                             goingToNodeID: wire.toNodeID,
                                             toSymbolID: wire.toSymbolID)

        try scheduleNode(wire.toNodeID)

        let toNode = try nodePoly(nodeID: wire.toNodeID)!

        // is the target Input marked as "holds alive"? if so, then removing this wire should delete the node unless there is another holds-alive Input

        let wireToSymbol = try database.selectSymbol(symbolID: wire.toSymbolID)!.name

/* TODO cascading delete: Nodes are held alive by their Output wires, unless they are Input File System Nodes or they have no Output wires.
 if toNode.descriptor.staticInputPorts.first(where: { $0.name == wireToSymbol })?.cascadingDelete ?? false {
            let numberOfInboundWiresToTarget = try database.selectWires(goingToNodeID: wire.toNodeID, toSymbolID: wire.toSymbolID).count

            if numberOfInboundWiresToTarget == 0 {
                print("cascading delete of Node: \(toNode.description())")
                _ = try deleteNode(wire.toNodeID)
            }
        }
*/
        wiresModified = true

        //        if toNode


        // TODO: cascade deletion:
        // - After deleting the Wire, check the origin Node. If it has no output wires at all, delete it and follow all wires going TO the origin Node. These wires should be deleted using this deleteWire method, e.g. recursive.
/*
        let numberOfInboundWiresToOrigin = try database.selectWires(goingToNodeID: wire.fromNodeID).count
        let numberOfOutboundWiresFromOrigin = try database.selectWires(comingFromNodeID: wire.fromNodeID).count

        if numberOfInboundWiresToOrigin == 0 || numberOfOutboundWiresFromOrigin == 0 {
            // Delete origin node if it is not Egress/Ingress
            _ = try deleteNode(fromNodeID)
        }

        let numberOfInboundWiresToTarget = try database.selectWires(goingToNodeID: wire.toNodeID).count
        let numberOfOutboundWiresFromTarget = try database.selectWires(comingFromNodeID: wire.toNodeID).count

        if numberOfInboundWiresToTarget == 0 || numberOfOutboundWiresFromTarget == 0 {
            // Delete target node if it is not Egress/Ingress
            _ = try deleteNode(toNodeID)
        }
*/
        // - Do the same for the target Node. Also follow the wires going TO the target Node.
        // -
        // 1. if a Node has no inputs, it shall be deleted, except for Ingress and Egress Nodes, which must always exist
        // 2. if a Node has no outputs, it shall be deleted, except for Ingress and Egress Nodes, which must always exist
        // 3. If a Node is deleted, all outbound wires shall be deleted, which may in turn cause more Nodes to be deleted according to rules 1 and 2
        // 4. If a Node is deleted, all inbound wires shall be deleted, which may in turn cause more Nodes to be deleted according to rules 1 and 2

        // TODO! schedule Node!
        // TODO: invalidate node bc its input changed
        return result
    }
}
