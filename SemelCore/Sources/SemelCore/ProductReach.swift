// ProductReach.swift
// SemelCore
//
// Which products a node stops (B-142). An error belongs to one node, and what the person
// wants to know is which of the things they build it keeps from being built: the
// `OutputFile`s under `output:` the node feeds, found by walking the wires downstream.

import SemelDatabaseModels
import SemelNodeKit

/// The walk from a node down its wires to every product it feeds, memoised for the life of
/// one value: one per report, so a cascade of a hundred errors under one product walks the
/// shared part of the graph once.
///
/// A struct holding its memo rather than a function taking one, because the memo *is* the
/// point: every caller that names the products of several nodes asks through one value,
/// and `nodeVisits` is how a test holds it to that.
public struct ProductReach {

    /// One product a node stops, as the person sees it at the prompt.
    public struct Product: Hashable, Comparable {
        /// The product's path, `output:/Packages/libModels.a`. For a tree product whose
        /// entries are not known — the tree itself is what failed, so no manifest arrived —
        /// the tree's folder.
        public let path: String
        /// The folder of the tree product `path` belongs to (B-63), nil for a product
        /// named on its own. Equal to `path` when the entries are not known.
        public let treeFolder: String?

        public init(path: String, treeFolder: String?) {
            self.path       = path
            self.treeFolder = treeFolder
        }

        /// Whether this is what a person asking for `asked` means: the product at that
        /// path, or any entry of the tree product whose folder it is.
        public func isNamed(by asked: String) -> Bool {
            path == asked || treeFolder == asked
        }

        public static func < (lhs: Product, rhs: Product) -> Bool {
            (lhs.path, lhs.treeFolder ?? "") < (rhs.path, rhs.treeFolder ?? "")
        }
    }

    let database: DatabaseLayer

    /// What each node the walk has finished reaches. Exact per node, because the graph is
    /// a DAG: what is downstream of a node does not depend on the path the walk took to it.
    private var reached: [ObjectID: Set<Product>] = [:]

    /// How many nodes had their consumers read: one per node the walk entered, however
    /// many errors share it. The cost of a report, and what a test counts.
    public private(set) var nodeVisits = 0

    public init(database: DatabaseLayer) {
        self.database = database
    }

    /// Every product downstream of `nodeID` that holds no value, in path order. A node
    /// nothing under `output:` reads has none, and so has one whose products were built.
    public mutating func products(downstreamOf nodeID: ObjectID) -> [Product] {
        var walking: Set<ObjectID> = []
        return reach(nodeID, walking: &walking).sorted()
    }

    /// Every product downstream of any of `nodeIDs` — the several nodes one folded report
    /// stands for — each once, in path order.
    public mutating func products(downstreamOf nodeIDs: [ObjectID]) -> [Product] {
        var union: Set<Product> = []
        for nodeID in nodeIDs {
            var walking: Set<ObjectID> = []
            union.formUnion(reach(nodeID, walking: &walking))
        }
        return union.sorted()
    }

    /// The walk. It stops at the two kinds that end a chain: an `OutputFile` is the product,
    /// and a `ProjectBuilder` is the formula that publishes products — read through its
    /// `trees` port, it is one tree product; through any other, it is every product the
    /// formula holds, since a formula that cannot be read publishes none of them. Going on
    /// past a builder would reach the project finder and, from it, every project.
    ///
    /// Best effort, as every report is: a row or a wire the database cannot hand over
    /// leaves that branch out, which costs a product name rather than the report.
    private mutating func reach(_ nodeID: ObjectID, walking: inout Set<ObjectID>) -> Set<Product> {
        if let known = reached[nodeID] {
            return known
        }
        // Wire creation rejects a cycle, so this is a belt on a graph that cannot have one.
        guard walking.insert(nodeID).inserted else {
            return []
        }
        defer { walking.remove(nodeID) }
        nodeVisits += 1

        guard let nodeRecord = FatalErrors.attempt({ try database.node.find(nodeID: nodeID) }) ?? nil else {
            reached[nodeID] = []
            return []
        }

        var found: Set<Product> = []
        switch nodeRecord.kind {
        case OutputFile.kind:
            if let product = product(publishedBy: nodeRecord) {
                found.insert(product)
            }
        case ProjectBuilder.kind:
            found = productsHeld(byBuilder: nodeID, walking: &walking)
        default:
            let treesPort = ProjectBuilder.treesInputPort.asSymbolID()
            let consumers = FatalErrors.attempt({ try database.wire.select(comingFromNodeID: nodeID) }) ?? []
            for wire in consumers {
                if wire.toSymbolID == treesPort, isBuilder(wire.toNodeID) {
                    let folder = wire.name.resolveSymbol()
                    found.insert(Product(path: folder, treeFolder: folder))
                    continue
                }
                found.formUnion(reach(wire.toNodeID, walking: &walking))
            }
        }

        reached[nodeID] = found
        return found
    }

    /// Whether `nodeID` is a `ProjectBuilder`, asked once per wire into a `trees` port,
    /// which no other kind declares — a cheap question, kept for a node of another type
    /// that names a port the same.
    private func isBuilder(_ nodeID: ObjectID) -> Bool {
        (FatalErrors.attempt({ try database.node.find(nodeID: nodeID) }) ?? nil)?.kind == ProjectBuilder.kind
    }

    /// Every product a formula's builder holds: the `OutputFile`s wired to its `input`
    /// port, and the folder of each tree product none of whose entries is among them yet.
    private mutating func productsHeld(byBuilder builderID: ObjectID, walking: inout Set<ObjectID>) -> Set<Product> {
        var found: Set<Product> = []
        let productWires = FatalErrors.attempt({
            try database.wire.select(goingToNodeID: builderID, toSymbolID: ProjectBuilder.productInputPort.asSymbolID())
        }) ?? []
        for wire in productWires {
            found.formUnion(reach(wire.fromNodeID, walking: &walking))
        }

        let treeWires = FatalErrors.attempt({
            try database.wire.select(goingToNodeID: builderID, toSymbolID: ProjectBuilder.treesInputPort.asSymbolID())
        }) ?? []
        let foldersWithEntries = Set(found.compactMap(\.treeFolder))
        for wire in treeWires {
            let folder = wire.name.resolveSymbol()
            if !foldersWithEntries.contains(folder) {
                found.insert(Product(path: folder, treeFolder: folder))
            }
        }
        return found
    }

    /// The product an `OutputFile` is, with the tree it belongs to when what it publishes
    /// is one entry of a tree: a `TreeFile` on its `input`, whose name is the entry's path
    /// within the tree, so the folder is the product's path with that name taken off.
    ///
    /// Nil for a product that holds a value: it was built from the inputs the graph holds
    /// now, so whatever failed above it did not stop it. A source nobody pushed that a
    /// settings merge reads as nothing to add is reported, and every product is downstream
    /// of it; naming them all as stopped would send the reader to the wrong place.
    private func product(publishedBy nodeRecord: NodeRecord) -> Product? {
        guard let path = nodeRecord.properties[OutputFile.pathProperty], let nodeID = nodeRecord.id else {
            return nil
        }
        let published = FatalErrors.attempt({ try nodeRecord.readFromInputPort(OutputFile.inputPort) }) ?? [:]
        if case .value? = published.values.first {
            return nil
        }
        let sources = FatalErrors.attempt({
            try database.wire.select(goingToNodeID: nodeID, toSymbolID: OutputFile.inputPort.asSymbolID())
        }) ?? []
        guard let source = sources.first,
              let sourceRecord = FatalErrors.attempt({ try database.node.find(nodeID: source.fromNodeID) }) ?? nil,
              sourceRecord.kind == TreeFile.kind,
              let entryName = sourceRecord.properties[TreeFile.nameProperty],
              path.hasSuffix("/\(entryName)") else {
            return Product(path: path, treeFolder: nil)
        }
        return Product(path: path, treeFolder: String(path.dropLast(entryName.count + 1)))
    }

    // MARK: - Naming a product

    /// Whether `path` — a full path under `output:` — names a product: an `OutputFile`
    /// stands there, or a formula publishes a tree product with that folder. What `errors
    /// <product>` asks before it filters, so a path that is no product is an error rather
    /// than an empty answer that reads as "nothing wrong".
    public static func isProduct(_ path: String, database: DatabaseLayer) throws -> Bool {
        let asked = Path(path)
        guard let relative = asked.relative(to: Path(FileSystemName.output)), !relative.isEmpty else {
            return false
        }
        if let nodeRecord = try Folder.outputFileSystem.childNode(path: relative), nodeRecord.kind == OutputFile.kind {
            return true
        }
        let treesPort = ProjectBuilder.treesInputPort.asSymbolID()
        for builder in try database.node.select(kind: ProjectBuilder.kind) {
            let treeWires = try database.wire.select(goingToNodeID: try builder.requireID(), toSymbolID: treesPort)
            if treeWires.contains(where: { $0.name.resolveSymbol() == asked.string }) {
                return true
            }
        }
        return false
    }
}
