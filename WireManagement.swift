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
//        try database.insertMessage(.init(kind: .wireConnected, targetNodeID: toNodeID, wireID: wireID, dataObjectHash: nil, priority: 0))
    }

    func connectWire(fromNode: NodeType,
                     fromPort: NodeKindDescriptor.OutputPort,
                     toNode: NodeType,
                     toPort: NodeKindDescriptor.InputPort) throws {

        try connectWire(fromNodeID: fromNode.nodeContext.nodeID!,
                        fromPort: fromPort.index,
                        toNodeID: toNode.nodeContext.nodeID!,
                        toPort: toPort.index)
    }

    func deleteWire(fromNode: NodeType,
                    fromPort: NodeKindDescriptor.OutputPort,
                    toNode: NodeType,
                    toPort: NodeKindDescriptor.InputPort) throws -> Bool {

        try deleteWire(fromNodeID: fromNode.nodeContext.nodeID!,
                       fromPort: fromPort.index,
                       toNodeID: toNode.nodeContext.nodeID!,
                       toPort: toPort.index)
    }

    func findNodeConnectedToNodeViaInputWire(_ toNode: NodeType, named name: String, fromPort: String) throws -> (any NodeType)? {
        for wire in try database.selectWires(goingToNodeID: toNode.nodeContext.nodeID!) {

            let fromNode = try wire.fromNodeID.loadNode(from: database)

            if fromNode.name == name {
                return try wrapRawNodePoly(nodeRaw: fromNode)
            }
        }
        return nil
    }

    func deleteNodeAndConnectingWires(nodeID: ObjectID) {
    }

    private func deleteWire(fromNodeID: ObjectID,
                            fromPort: UInt8,
                            toNodeID: ObjectID,
                            toPort: UInt8) throws -> Bool {

        let wires = try database.selectWires(comingFromNodeID: fromNodeID,
                                             fromPort: fromPort,
                                             goingToNodeID: toNodeID,
                                             toPort: toPort)

        // There should only be 0 or 1 wires..

        guard let wire = wires.first else {
            return false
        }

        let result = try database.deleteWire(wireID: wire.id!)
//        try database.insertMessage(.init(kind: .wireDisconnected, targetNodeID: toNodeID, wireID: wire.id!, dataObjectHash: nil, priority: 0))

        // TODO: cascade deletion:
        // - After deleting the Wire, check the origin Node. If it has no output wires at all, delete it and follow all wires going TO the origin Node. These wires should be deleted using this deleteWire method, e.g. recursive.

        let numberOfInboundWiresToOrigin = try database.selectWires(goingToNodeID: fromNodeID).count
        let numberOfOutboundWiresFromOrigin = try database.selectWires(comingFromNodeID: fromNodeID).count

        if numberOfInboundWiresToOrigin == 0 || numberOfOutboundWiresFromOrigin == 0 {
            // Delete origin node if it is not Egress/Ingress
            deleteNodeAndConnectingWires(nodeID: fromNodeID)
        }

        let numberOfInboundWiresToTarget = try database.selectWires(goingToNodeID: toNodeID).count
        let numberOfOutboundWiresFromTarget = try database.selectWires(comingFromNodeID: toNodeID).count

        if numberOfInboundWiresToTarget == 0 || numberOfOutboundWiresFromTarget == 0 {
            // Delete target node if it is not Egress/Ingress
            deleteNodeAndConnectingWires(nodeID: toNodeID)
        }

        // - Do the same for the target Node. Also follow the wires going TO the target Node.
        // -
        // 1. if a Node has no inputs, it shall be deleted, except for Ingress and Egress Nodes, which must always exist
        // 2. if a Node has no outputs, it shall be deleted, except for Ingress and Egress Nodes, which must always exist
        // 3. If a Node is deleted, all outbound wires shall be deleted, which may in turn cause more Nodes to be deleted according to rules 1 and 2
        // 4. If a Node is deleted, all inbound wires shall be deleted, which may in turn cause more Nodes to be deleted according to rules 1 and 2

        return result
    }
}
