// NodeIdentity.swift
// SemelNodeKit
//
// What makes a node the node it is (B-115): its kind, its properties, and — for each
// static input port, for each named wire — the wire's name, the identity of the node the
// wire comes from and the output port it comes from. Folded as a hash, so the identity of
// a node is one level deep however deep the graph below it is: a Merkle tree over the
// graph, the way a folder's content root is one over a folder.
//
// The same identity is computed two ways and has to agree: from a demanded spec tree,
// children first, with no database; and from a stored node's row and its wires, one level,
// reading each source's stored identity. `check` compares the two.

import CryptoKit
import Foundation

public enum NodeIdentity {

    /// One wire of one static port, as the identity sees it.
    public struct Wire: Equatable {
        public let name: String
        public let sourceIdentity: String
        public let sourcePort: String

        public init(name: String, sourceIdentity: String, sourcePort: String) {
            self.name = name
            self.sourceIdentity = sourceIdentity
            self.sourcePort = sourcePort
        }
    }

    /// One static input port's wires.
    public struct Port: Equatable {
        public let name: String
        public let wires: [Wire]

        public init(name: String, wires: [Wire]) {
            self.name = name
            self.wires = wires
        }
    }

    /// How many characters of an identity a person is shown: enough to tell nodes apart
    /// in a dump, where a collision would need two of the few thousand nodes there to
    /// share eight hex digits. The full value is on the node's row.
    public static let shownLength = 8

    /// The identity, 64 hex characters, of a node with these parts. Properties, ports and
    /// wires are sorted here, so the order a caller lists them in — a formula's line order,
    /// a dictionary's iteration order, the order wires came back from a query — cannot make
    /// one node two.
    ///
    /// The material is a stated text, every field framed by its length, for the reason
    /// `FolderContentRoot`'s document is: an identity outlives the release that computed
    /// it, so every byte of what it hashes has to be a decision and never a value that
    /// happens to run into the next. The kind is hashed rather than the type's name, so a
    /// rename of a node type is a change to source and not to every node below it.
    public static func hash(kind: UInt, properties: [(key: String, value: String)], ports: [Port]) -> String {
        var material = "semel-node-identity 1\n"
        material += "kind \(kind)\n"
        for property in properties.sorted(by: { $0.key < $1.key }) {
            material += "property \(framed(property.key)) \(framed(property.value))\n"
        }
        // A port with no wires is not part of what the node is: a demanded tree names
        // only the ports it wires, and a node's row has every port its type declares, so
        // the two agree only if silence about a port means the same on both sides.
        for port in ports.sorted(by: { $0.name < $1.name }) where !port.wires.isEmpty {
            material += "port \(framed(port.name))\n"
            for wire in port.wires.sorted(by: { ($0.name, $0.sourceIdentity, $0.sourcePort) < ($1.name, $1.sourceIdentity, $1.sourcePort) }) {
                material += "wire \(framed(wire.name)) \(wire.sourceIdentity) \(framed(wire.sourcePort))\n"
            }
        }
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A value preceded by its length in bytes, so a tab or a newline in a path changes
    /// the identity and never the shape of the material.
    private static func framed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    /// The first `shownLength` characters, for a person.
    public static func shown(_ identity: String) -> String {
        String(identity.prefix(shownLength))
    }
}

// MARK: - The identity of a demanded tree

/// A tree that names nothing the identity can be taken of.
public enum GraphSpecIdentityError: Error, CustomStringConvertible {
    /// The tree names a type this Semel does not link, so it has no kind.
    case unknownTypeName(String)
    /// A wire's source names no output port; a wire without one carries nothing.
    case wireWithoutOutputPort(wire: String, typeName: String)

    public var description: String {
        switch self {
        case .unknownTypeName(let typeName):
            return "no node type is registered under the name '\(typeName)'"
        case .wireWithoutOutputPort(let wire, let typeName):
            return "the \(typeName) feeding the wire '\(wire)' names no output port to take a value from"
        }
    }
}

extension GraphSpecNode {

    /// The identity of the node this tree describes — the one the engine would find or
    /// create for it — computed children first, with no database. A tree parsed from a
    /// formula names its type; the kind comes from the registry, as it does at creation.
    public func identity() throws -> String {
        guard let kind = try? TypeRegistry.kind(forTypeName: typeName) else {
            throw GraphSpecIdentityError.unknownTypeName(typeName)
        }
        let ports = try inputs.map { port in
            NodeIdentity.Port(name: port.portName, wires: try port.wires.map { wire in
                guard let sourcePort = wire.node.outputPort else {
                    throw GraphSpecIdentityError.wireWithoutOutputPort(wire: wire.name, typeName: wire.node.typeName)
                }
                return NodeIdentity.Wire(name: wire.name, sourceIdentity: try wire.node.identity(), sourcePort: sourcePort)
            })
        }
        return NodeIdentity.hash(kind: kind, properties: properties.map { ($0.key, $0.value) }, ports: ports)
    }
}
