//
//  GraphSpecTableTests.swift
//  SemelNodeKitTests
//
//  B-121. A node's demanded specs, stored with each distinct spec node once. The trees a
//  product builder demands repeat the settings chain under every compile; the table folds
//  them by the identity the graph stores, and must unfold to what was folded.
//

@testable import SemelNodeKit
import XCTest

// MARK: - Stand-in node types

/// The identity is taken over a type's kind, so folding needs types the registry knows.
/// These have kinds and nothing else: a fold never makes a node.
private struct SpecTableSource: WithKind {
    static let kind: UInt = 987_301
}

private struct SpecTableSettings: WithKind {
    static let kind: UInt = 987_302
}

private struct SpecTableFilter: WithKind {
    static let kind: UInt = 987_303
}

private struct SpecTableCompiler: WithKind {
    static let kind: UInt = 987_304
}

final class GraphSpecTableTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        try TypeRegistry.register(types: [SpecTableSource.self, SpecTableSettings.self,
                                          SpecTableFilter.self, SpecTableCompiler.self])
    }

    // MARK: - Trees

    /// How many settings nodes are layered over the settings file: a product's chain lays
    /// the machine's, the project's, the package's and the target's settings over each
    /// other.
    private let settingsLayers = 6

    /// The settings every compile is configured from: a file with layers laid over it.
    private func settings() -> GraphSpecNode {
        var layered = GraphSpecNode(SpecTableSource.self, properties: ["path": "input:/semel.config"]).port("output")
        for layer in 0..<settingsLayers {
            layered = GraphSpecNode(SpecTableSettings.self, properties: ["role": "layer \(layer)"], inputs: [
                "base": ["settings": layered],
            ]).port("output")
        }
        return layered
    }

    /// A compile of one source, configured through its own filter of the shared settings.
    private func compile(_ path: String) -> GraphSpecNode {
        GraphSpecNode(SpecTableCompiler.self, properties: ["module": "App"], inputs: [
            "configuration": ["config": GraphSpecNode(SpecTableFilter.self, properties: ["prefix": "swift.compiler"],
                                                      inputs: ["input": ["settings": settings()]]).port("output")],
            "input": [path: GraphSpecNode(SpecTableSource.self, properties: ["path": path]).port("output")],
        ]).port("object")
    }

    /// What a linker's builder demands: one wire per compile, each spelling out the whole
    /// settings chain again.
    private func demands(sources: Int) -> [String: [String: GraphSpecNode]] {
        let paths = (0..<sources).map { "input:/Sources/File\($0).swift" }
        return ["objects": Dictionary(uniqueKeysWithValues: paths.map { ($0, compile($0)) })]
    }

    /// Every node of a tree, at every depth, once per occurrence.
    private func occurrences(of specNode: GraphSpecNode) -> [GraphSpecNode] {
        [specNode] + specNode.inputs.flatMap { $0.wires.flatMap { occurrences(of: $0.node) } }
    }

    // MARK: - Folding

    /// The point of the table: a node reached by many paths is written once. Forty
    /// compiles share one filter and the settings chain under it; each has its own compile
    /// and its own source file.
    func test_aNodeReachedByManyPathsIsOneRow() throws {
        let table = try GraphSpecTable(trees: demands(sources: 40))

        XCTAssertEqual(table.rows.count, 40 + 40 + 1 + settingsLayers + 1,
                       "a row per compile and per source file, and one for each shared node")
    }

    /// A row is filed under the identity the graph stores for its node, so the table's keys
    /// are the graph's identities and a demand's reference is the identity the applier
    /// would compute from the tree.
    func test_eachRowIsFiledUnderTheIdentityOfItsTree() throws {
        let trees = demands(sources: 5)
        let table = try GraphSpecTable(trees: trees)

        for (wireName, tree) in trees["objects"]!.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(table.inputWireSpecs["objects"]?[wireName],
                           GraphSpecTable.Reference(identity: try tree.identity(), outputPort: "object"))
            for occurrence in occurrences(of: tree) {
                let row = try XCTUnwrap(table.rows[try occurrence.identity()], "no row for \(occurrence.typeName)")
                XCTAssertEqual(row.typeName, occurrence.typeName)
                XCTAssertEqual(row.properties, occurrence.properties)
            }
        }
    }

    /// Two occurrences of one node that list its wires in another order are one node — the
    /// identity sorts them — and so one row.
    func test_oneNodeListedInTwoOrdersIsOneRow() throws {
        let first  = GraphSpecNode(SpecTableSource.self, properties: ["path": "a"]).port("output")
        let second = GraphSpecNode(SpecTableSource.self, properties: ["path": "b"]).port("output")
        let inOrder = GraphSpecNode(typeName: "SpecTableFilter", inputs: [
            GraphSpecInputPort(portName: "input", wires: [GraphSpecWire(name: "a", node: first),
                                                          GraphSpecWire(name: "b", node: second)]),
        ], outputPort: "output")
        let reversed = GraphSpecNode(typeName: "SpecTableFilter", inputs: [
            GraphSpecInputPort(portName: "input", wires: [GraphSpecWire(name: "b", node: second),
                                                          GraphSpecWire(name: "a", node: first)]),
        ], outputPort: "output")

        let table = try GraphSpecTable(trees: ["input": ["one": inOrder, "two": reversed]])

        XCTAssertEqual(table.rows.count, 3)
        XCTAssertEqual(table.inputWireSpecs["input"]?["one"], table.inputWireSpecs["input"]?["two"])
    }

    /// A tree naming a type this Semel does not link has no identity, so nothing to be
    /// filed under.
    func test_aTreeNamingAnUnlinkedTypeDoesNotFold() {
        let tree = GraphSpecNode(typeName: "RetiredCompiler", outputPort: "object")

        XCTAssertThrowsError(try GraphSpecTable(trees: ["input": ["a": tree]])) { error in
            guard case GraphSpecIdentityError.unknownTypeName("RetiredCompiler") = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    // MARK: - Unfolding

    /// What goes in comes back: every port, every wire, every tree, to the output port a
    /// demand reads.
    func test_theTreesComeBackAsTheyWereFolded() throws {
        let trees = demands(sources: 12)

        XCTAssertEqual(try GraphSpecTable(trees: trees).trees(), trees)
    }

    /// A port named with no wires asks for every wire on it to go, so it is kept as a port
    /// with none rather than dropped — which would keep them.
    func test_aPortWithNoWiresComesBackAsOne() throws {
        let trees: [String: [String: GraphSpecNode]] = ["input": [:], "objects": ["a": compile("a")]]

        XCTAssertEqual(try GraphSpecTable(trees: trees).trees(), trees)
    }

    /// A demand whose tree names no output port is kept as it is: the applier is what
    /// refuses to wire one, and says so.
    func test_aDemandWithoutAnOutputPortComesBackWithout() throws {
        let tree = GraphSpecNode(SpecTableSource.self, properties: ["path": "a"])
        let table = try GraphSpecTable(trees: ["input": ["a": tree]])

        XCTAssertNil(table.inputWireSpecs["input"]?["a"]?.outputPort)
        XCTAssertEqual(try table.trees(), ["input": ["a": tree]])
    }

    /// The unfolded tree hashes to the identity it was filed under, so the node the applier
    /// finds for it is the node the fold named.
    func test_anUnfoldedTreeHasTheIdentityItWasFiledUnder() throws {
        let table = try GraphSpecTable(trees: demands(sources: 3))
        let unfolded = try table.trees()

        for (wireName, reference) in table.inputWireSpecs["objects"]!.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(try unfolded["objects"]?[wireName]?.identity(), reference.identity)
        }
    }

    /// A reference to a row the table does not hold is a damaged entry, not a crash.
    func test_aTableMissingARowDoesNotUnfold() {
        let missing = String(repeating: "a", count: 64)
        let table = GraphSpecTable(inputWireSpecs: ["input": ["a": .init(identity: missing, outputPort: "output")]],
                                   rows: [:])

        XCTAssertThrowsError(try table.trees()) { error in
            guard case GraphSpecTableError.missingRow(missing) = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    /// A fold cannot write a row among its own sources, but a stored table is read as it
    /// stands: a damaged one is refused rather than recursed into for ever.
    func test_aTableWithACycleDoesNotUnfold() {
        let looped = String(repeating: "b", count: 64)
        let row = GraphSpecTable.Row(typeName: "SpecTableFilter", properties: [], inputs: [
            .init(portName: "input", wires: [.init(name: "self", source: .init(identity: looped, outputPort: "output"))]),
        ])
        let table = GraphSpecTable(inputWireSpecs: ["input": ["a": .init(identity: looped, outputPort: "output")]],
                                   rows: [looped: row])

        XCTAssertThrowsError(try table.trees()) { error in
            guard case GraphSpecTableError.cycle(looped) = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    // MARK: - What a reader asks of a stored table

    /// A table written by a Semel that linked a type this one does not is read by name,
    /// at any depth, once per row.
    func test_aRowNamingAnUnlinkedTypeIsReported() throws {
        let linked = try GraphSpecTable(trees: demands(sources: 2))
        XCTAssertTrue(linked.namesOnlyRegisteredTypes())

        let retired = String(repeating: "c", count: 64)
        var rows = linked.rows
        rows[retired] = GraphSpecTable.Row(typeName: "RetiredCompiler", properties: [], inputs: [])
        let unlinked = GraphSpecTable(inputWireSpecs: linked.inputWireSpecs, rows: rows)

        XCTAssertFalse(unlinked.namesOnlyRegisteredTypes())
    }

    // MARK: - Encoding

    /// The table is stored as JSON with sorted keys, so two folds of equal trees are the
    /// same bytes whatever order their dictionaries were built in — a cache entry is
    /// compared, diffed and hashed as bytes.
    func test_equalTreesEncodeToTheSameBytes() throws {
        let trees = demands(sources: 20)
        let rebuilt = ["objects": Dictionary(uniqueKeysWithValues: trees["objects"]!.sorted { $0.key > $1.key }.map { ($0.key, $0.value) })]

        let first  = try GraphSpecTable(trees: trees).toJSON()
        let second = try GraphSpecTable(trees: rebuilt).toJSON()

        XCTAssertEqual(first, second)
        XCTAssertEqual(try GraphSpecTable.fromJSON(first), try GraphSpecTable(trees: trees))
    }

    /// What the table is for, measured: a demand whose settings chain repeats under every
    /// compile grows by one compile's rows per compile rather than by one compile's whole
    /// tree, so it is a fraction of the trees' size — a fraction set by how deep the shared
    /// part is, which in a real product is far deeper than here.
    func test_theTableIsAFractionOfTheTreesItFolds() throws {
        let trees = demands(sources: 200)

        let treeBytes  = try trees.toJSON().utf8.count
        let tableBytes = try GraphSpecTable(trees: trees).toJSON().utf8.count

        XCTAssertLessThan(tableBytes * 2, treeBytes, "table \(tableBytes) bytes, trees \(treeBytes)")
    }
}
