// NodeIdentity+Graph.swift
// SemelCore
//
// A stored node's identity, recomputed from the graph (B-115): its row's kind and
// properties, and for each static port each wire's name, the stored identity of the node
// it comes from and the port it comes from. One level, because every source carries its
// own identity already — that is what makes the identity a fold rather than a walk.

import SemelDatabaseModels
import SemelNodeKit

/// A node whose identity cannot be recomputed: a source with none.
enum NodeIdentityError: Error, CustomStringConvertible {
    case sourceWithoutIdentity(nodeID: ObjectID)

    var description: String {
        switch self {
        case .sourceWithoutIdentity(let nodeID):
            return "node #\(nodeID) has no identity, so nothing wired from it can compute its own"
        }
    }
}

extension NodeRecord {

    /// The identity this row gives itself over `wires`, every wire into this node, with
    /// the caller answering what a symbol is called and what identity a source carries.
    /// Pure, so `check` can ask it of a graph it has already read whole, without a query
    /// per node and without touching a table it found unreadable.
    func recomputedIdentity(wiresIn wires: [Wire],
                            staticPorts: [String],
                            symbolName: (ObjectID) -> String,
                            sourceIdentity: (ObjectID) throws -> String) throws -> String {
        let ports = try staticPorts.map { portName in
            NodeIdentity.Port(name: portName, wires: try wires
                .filter { symbolName($0.toSymbolID) == portName }
                .map { wire in
                    NodeIdentity.Wire(name: symbolName(wire.name),
                                      sourceIdentity: try sourceIdentity(wire.fromNodeID),
                                      sourcePort: symbolName(wire.fromSymbolID))
                })
        }
        return NodeIdentity.hash(kind: kind, properties: properties.map { ($0.key, $0.value) }, ports: ports)
    }

    /// The same, read from the database for one node: what `check` recomputes for it.
    func recomputedIdentity(database: DatabaseLayer) throws -> String {
        let node = try makeNode()
        let wires = try database.wire.select(goingToNodeID: try requireID())
        return try recomputedIdentity(wiresIn: wires,
                                      staticPorts: node.descriptor.staticInputPorts,
                                      symbolName: { $0.resolveSymbol() },
                                      sourceIdentity: { sourceID in
                                          guard let identity = try database.node.select(nodeID: sourceID).identity else {
                                              throw NodeIdentityError.sourceWithoutIdentity(nodeID: sourceID)
                                          }
                                          return identity
                                      })
    }
}
