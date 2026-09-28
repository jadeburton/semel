// GraphSpecTable.swift
// SemelNodeKit
//
// A node's demanded wire specs with every distinct spec node written once (B-121).
//
// A `GraphSpecNode` is the whole tree above a wire, spelled out: a node reached by two
// paths appears twice, and in a product's demand the settings chain under every compile
// appears thousands of times. The table keeps one row per identity — the same identity the
// graph stores for the node (B-115), so a row's key is the node's `Node.identity` — and
// each row names the sources of its wires by identity and output port, as the graph's
// wires do. The demanded wires are references into the table. Folding and unfolding are
// pure: no database, only the type registry the identity needs for a kind. The engine's
// applier walks the rows by identity (`GraphSpecTableApplier`), so a table is how every
// demand reaches the graph, a fresh one as well as a cached one.

import Foundation

public struct GraphSpecTable: Equatable, Codable {

    /// Where a wire comes from: the node, by identity, and the output port it is read at.
    /// The port is nil only for a demanded tree that names none, which the applier refuses
    /// to wire; the source of a wire inside the table always names one, or it would have
    /// had no identity to be folded under.
    public struct Reference: Equatable, Hashable, Codable {
        public let identity:   String
        public let outputPort: String?

        public init(identity: String, outputPort: String?) {
            self.identity   = identity
            self.outputPort = outputPort
        }
    }

    /// One named wire of one of a row's static ports.
    public struct Wire: Equatable, Codable {
        public let name:   String
        public let source: Reference

        public init(name: String, source: Reference) {
            self.name   = name
            self.source = source
        }
    }

    /// One static input port of a row, with its wires in the order the tree listed them.
    public struct Port: Equatable, Codable {
        public let portName: String
        public let wires:    [Wire]

        public init(portName: String, wires: [Wire]) {
            self.portName = portName
            self.wires    = wires
        }
    }

    /// One distinct spec node: what its identity is taken of, with the type named rather
    /// than numbered. The name is what a reader of a stored entry has to check against
    /// what this Semel links (`namesOnlyRegisteredTypes`), and what unfolds back into a
    /// tree; the kind is only ever needed to hash.
    ///
    /// Properties, ports and wires keep the order of the first occurrence folded, which is
    /// the order a node created from the tree is wired in.
    public struct Row: Equatable, Codable {
        public let typeName:   String
        public let properties: [GraphSpecProperty]
        public let inputs:     [Port]

        public init(typeName: String, properties: [GraphSpecProperty], inputs: [Port]) {
            self.typeName   = typeName
            self.properties = properties
            self.inputs     = inputs
        }
    }

    /// What the table was folded from, as references: per input port, per wire name, the
    /// node the wire should come from and the port it is read at.
    public let inputWireSpecs: [String: [String: Reference]]
    /// Every distinct node the demands reach, by identity.
    public let rows: [String: Row]

    /// A table as it stands — what a decoder does, and what a test does to write an entry
    /// that no fold of this Semel's trees would produce.
    public init(inputWireSpecs: [String: [String: Reference]], rows: [String: Row]) {
        self.inputWireSpecs = inputWireSpecs
        self.rows           = rows
    }
}

// MARK: - Folding

/// A table that cannot be unfolded — a damaged entry, since a fold writes neither shape.
public enum GraphSpecTableError: Error, CustomStringConvertible {
    case missingRow(identity: String)
    case cycle(identity: String)

    public var description: String {
        switch self {
        case .missingRow(let identity):
            return "a stored spec table names the node \(NodeIdentity.shown(identity)) and holds no row for it"
        case .cycle(let identity):
            return "a stored spec table has the node \(NodeIdentity.shown(identity)) among its own sources"
        }
    }
}

extension GraphSpecTable {

    /// Folds demanded trees into a table: each node hashed once per occurrence, children
    /// first, and written once per identity.
    ///
    /// Ports and wires are folded in sorted order, so which occurrence of an identity is
    /// "first" — and so the order its row keeps — is the same in every process. Two
    /// occurrences of one identity differ at most in the order they list properties, ports
    /// and wires, which the identity does not see; they are one node in the graph, created
    /// once, and the table keeps one of them.
    ///
    /// `outputs` is not folded. It is outside the identity and nothing matches or creates
    /// through it, so a table unfolds to trees whose `outputs` are empty.
    public init(trees: [String: [String: GraphSpecNode]]) throws {
        var folder = GraphSpecFolder()
        var references: [String: [String: Reference]] = [:]
        for (portName, wireTrees) in trees.sorted(by: { $0.key < $1.key }) {
            var portReferences: [String: Reference] = [:]
            for (wireName, specNode) in wireTrees.sorted(by: { $0.key < $1.key }) {
                portReferences[wireName] = Reference(identity: try folder.fold(specNode),
                                                     outputPort: specNode.outputPort)
            }
            references[portName] = portReferences
        }
        self.init(inputWireSpecs: references, rows: folder.rows)
    }

    /// One tree folded on its own — a formula's product, a root the engine makes — as the
    /// rows it reaches and the reference to its root. The table demands nothing: there is
    /// no port for the tree to be wired to, only a node to find or create.
    public static func folding(tree specNode: GraphSpecNode) throws -> (table: GraphSpecTable, root: Reference) {
        var folder = GraphSpecFolder()
        let root = Reference(identity: try folder.fold(specNode), outputPort: specNode.outputPort)
        return (GraphSpecTable(inputWireSpecs: [:], rows: folder.rows), root)
    }

    /// Whether every row names a node type this Semel links — the question a reader of a
    /// stored table asks before acting on it, asked once per distinct node rather than
    /// once per occurrence.
    public func namesOnlyRegisteredTypes() -> Bool {
        rows.values.allSatisfy { (try? TypeRegistry.kind(forTypeName: $0.typeName)) != nil }
    }

    /// Whether every reference — each demand and each row's wires — names a row the table
    /// holds. A fold writes no other kind, so a table that fails this is damaged; asked
    /// with one lookup per reference and no hash, which is what lets a reader refuse a
    /// damaged table without unfolding it.
    public func referencesOnlyHeldRows() -> Bool {
        let demands = inputWireSpecs.values.allSatisfy { references in
            references.values.allSatisfy { rows[$0.identity] != nil }
        }
        return demands && rows.values.allSatisfy { row in
            row.inputs.allSatisfy { port in
                port.wires.allSatisfy { rows[$0.source.identity] != nil }
            }
        }
    }
}

/// The fold's working state: the rows written so far.
private struct GraphSpecFolder {
    var rows: [String: GraphSpecTable.Row] = [:]

    /// The identity of `specNode`, with its row and every row below it written. The same
    /// hash `GraphSpecNode.identity()` takes, reached by the same recursion, so the key a
    /// row is filed under is the identity the graph stores for the node.
    mutating func fold(_ specNode: GraphSpecNode) throws -> String {
        guard let kind = try? TypeRegistry.kind(forTypeName: specNode.typeName) else {
            throw GraphSpecIdentityError.unknownTypeName(specNode.typeName)
        }
        var rowPorts: [GraphSpecTable.Port] = []
        for port in specNode.inputs {
            var rowWires: [GraphSpecTable.Wire] = []
            for wire in port.wires {
                // Asked before the source is folded, so the error names the tree's own
                // node rather than whatever lies below it.
                guard let sourcePort = wire.node.outputPort else {
                    throw GraphSpecIdentityError.wireWithoutOutputPort(wire: wire.name, typeName: wire.node.typeName)
                }
                rowWires.append(GraphSpecTable.Wire(name: wire.name,
                                                    source: .init(identity: try fold(wire.node), outputPort: sourcePort)))
            }
            rowPorts.append(GraphSpecTable.Port(portName: port.portName, wires: rowWires))
        }
        let row = GraphSpecTable.Row(typeName: specNode.typeName, properties: specNode.properties, inputs: rowPorts)
        let identity = try row.identity(kind: kind, sourceTypeName: { rows[$0]?.typeName })
        if rows[identity] == nil {
            rows[identity] = row
        }
        return identity
    }
}

// MARK: - A row's own identity

extension GraphSpecTable {

    /// The row filed under `identity`: what the applier reads for a node it has to make.
    public func row(identity: String) throws -> Row {
        guard let row = rows[identity] else {
            throw GraphSpecTableError.missingRow(identity: identity)
        }
        return row
    }

    /// The identity `row` gives itself: its kind, its properties and, per port and wire,
    /// the identity and port of the source — the identity the row names, not one computed
    /// from the row below it. One level, as `NodeRecord.recomputedIdentity` is, so it costs
    /// one hash however deep the table is; a fold files a row under this, and the applier
    /// asks it of a row before making a node from it, because a stored table's keys are
    /// read as they stand.
    public func identity(of row: Row) throws -> String {
        guard let kind = try? TypeRegistry.kind(forTypeName: row.typeName) else {
            throw GraphSpecIdentityError.unknownTypeName(row.typeName)
        }
        return try row.identity(kind: kind, sourceTypeName: { rows[$0]?.typeName })
    }
}

extension GraphSpecTable.Row {

    /// The hash itself, over a kind the caller has already looked up. A wire whose source
    /// names no port has nothing to hash, as in a tree; `sourceTypeName` names that source
    /// for the error, when the table holds it.
    func identity(kind: UInt, sourceTypeName: (String) -> String?) throws -> String {
        let ports = try inputs.map { port in
            NodeIdentity.Port(name: port.portName, wires: try port.wires.map { wire in
                guard let sourcePort = wire.source.outputPort else {
                    throw GraphSpecIdentityError.wireWithoutOutputPort(
                        wire: wire.name,
                        typeName: sourceTypeName(wire.source.identity) ?? NodeIdentity.shown(wire.source.identity))
                }
                return NodeIdentity.Wire(name: wire.name, sourceIdentity: wire.source.identity, sourcePort: sourcePort)
            })
        }
        return NodeIdentity.hash(kind: kind, properties: properties.map { ($0.key, $0.value) }, ports: ports)
    }
}

// MARK: - Unfolding

extension GraphSpecTable {

    /// The demanded trees back, one per wire.
    ///
    /// The engine never asks for them: its applier walks the rows by identity and builds
    /// no tree. This is the reader's view of a table, and what shows that a fold loses
    /// nothing a tree said — the property that lets the applier read the table instead.
    ///
    /// Each distinct node is built once and shared by every tree that reaches it: a tree's
    /// arrays are copy-on-write, so the thousand occurrences of one settings chain are one
    /// value in memory, as they are one row on disk.
    public func trees() throws -> [String: [String: GraphSpecNode]] {
        var unfolder = GraphSpecUnfolder(rows: rows)
        var trees: [String: [String: GraphSpecNode]] = [:]
        for (portName, references) in inputWireSpecs.sorted(by: { $0.key < $1.key }) {
            var portTrees: [String: GraphSpecNode] = [:]
            for (wireName, reference) in references.sorted(by: { $0.key < $1.key }) {
                portTrees[wireName] = try unfolder.tree(for: reference)
            }
            trees[portName] = portTrees
        }
        return trees
    }
}

/// The unfold's working state: each identity's tree, in its node-identity form, once built.
private struct GraphSpecUnfolder {
    let rows: [String: GraphSpecTable.Row]
    var built: [String: GraphSpecNode] = [:]
    var unfolding: Set<String> = []

    init(rows: [String: GraphSpecTable.Row]) {
        self.rows = rows
    }

    mutating func tree(for reference: GraphSpecTable.Reference) throws -> GraphSpecNode {
        let specNode = try tree(identity: reference.identity)
        return GraphSpecNode(typeName: specNode.typeName, properties: specNode.properties,
                             inputs: specNode.inputs, outputPort: reference.outputPort)
    }

    /// Recursion is as deep as the demanded graph, which is what folding it took too. A
    /// fold cannot write a cycle — a row's identity is a hash over its sources' identities,
    /// so one would need a hash that contains itself — but a stored table is read as it
    /// stands, keys unverified, and a damaged one must be a miss and not a stack overflow.
    private mutating func tree(identity: String) throws -> GraphSpecNode {
        if let specNode = built[identity] {
            return specNode
        }
        guard let row = rows[identity] else {
            throw GraphSpecTableError.missingRow(identity: identity)
        }
        guard unfolding.insert(identity).inserted else {
            throw GraphSpecTableError.cycle(identity: identity)
        }
        defer { unfolding.remove(identity) }
        let inputs = try row.inputs.map { port in
            GraphSpecInputPort(portName: port.portName, wires: try port.wires.map { wire in
                GraphSpecWire(name: wire.name, node: try tree(for: wire.source))
            })
        }
        let specNode = GraphSpecNode(typeName: row.typeName, properties: row.properties, inputs: inputs)
        built[identity] = specNode
        return specNode
    }
}
