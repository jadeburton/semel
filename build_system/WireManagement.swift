//
//  WireManagement.swift
//  build_system
//
//  Created by Jade Burton on 28.02.26.
//

// Wire management
extension ProcessingCycle {

    private func connectWire(fromNodeID: ObjectID,
                             fromPort: UInt8,
                             toNodeID: ObjectID,
                             toPort: UInt8) throws {

        guard try database.selectWires(comingFromNodeID: fromNodeID,
                                       fromPort: fromPort,
                                       goingToNodeID: toNodeID,
                                       toPort: toPort).isEmpty else {
            return
        }

        // TODO: transactional
        // TODO: if there is a circular reference, block the creation of the Wire
        _ = try database.insertWire(.init(fromNodeID: fromNodeID, fromPort: fromPort, toNodeID: toNodeID, toPort: toPort))

        wiresModified = true

        try writePendingToAllOutputsOfNode(nodeID: toNodeID)

        try scheduleNode(toNodeID)
    }

    func connectWire(fromNode: NodeType,
                     fromPort: OutputPort,
                     toNode: NodeType,
                     toPort: InputPort) throws {

        try connectWire(fromNodeID: fromNode.nodeContext.nodeID!,
                        fromPort: fromPort.index,
                        toNodeID: toNode.nodeContext.nodeID!,
                        toPort: toPort.index)
    }

    func deleteWire(fromNode: NodeType,
                    fromPort: OutputPort,
                    toNode: NodeType,
                    toPort: InputPort) throws -> Bool {

        try deleteWire(fromNodeID: fromNode.nodeContext.nodeID!,
                       fromPort: fromPort.index,
                       toNodeID: toNode.nodeContext.nodeID!,
                       toPort: toPort.index)
    }

    func findNodeConnectedToNodeViaInputWire(_ toNode: NodeType, toInputPortNamed inputPortName: String) throws -> [any NodeType] {
        let inputPortDescriptor = toNode.descriptor.inputs.first(where: { $0.name == inputPortName })!

        return try database.selectWires(goingToNodeID: toNode.nodeContext.nodeID!, toPort: inputPortDescriptor.index).map { wire in
            try nodePoly(nodeID: wire.fromNodeID)!
        }
    }

    func deleteWire(fromNodeID: ObjectID,
                    fromPort: UInt8,
                    toNodeID: ObjectID,
                    toPort: UInt8) throws -> Bool {
        let wires = try database.selectWires(comingFromNodeID: fromNodeID,
                                             fromPort: fromPort,
                                             goingToNodeID: toNodeID,
                                             toPort: toPort)
        guard let wire = wires.first else {
            return false
        }

        return try deleteWire(wire)
    }

    func deleteWire(_ wire: Wire) throws -> Bool {

        print("delete wire #\(wire.id!)")

        let result = try database.deleteWire(wireID: wire.id!)

        try scheduleNode(wire.toNodeID)

        let toNode = try nodePoly(nodeID: wire.toNodeID)!

        // is the target Input marked as "holds alive"? if so, then removing this wire should delete the node unless there is another holds-alive Input

        if toNode.descriptor.inputs.first(where: { $0.index == wire.toPort })?.cascadingDelete ?? false {
            let numberOfInboundWiresToTarget = try database.selectWires(goingToNodeID: wire.toNodeID, toPort: wire.toPort).count

            if numberOfInboundWiresToTarget == 0 {
                print("cascading delete of Node: \(toNode.description())")
                _ = try deleteNode(wire.toNodeID)
            }
        }

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
