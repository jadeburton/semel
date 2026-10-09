//
//  ProductReachTests.swift
//  SemelCoreTests
//
//  B-142. Every error names the products it stops: the walk from the failing node down
//  its wires to every `OutputFile` it feeds, memoised so a cascade under one product walks
//  the shared part of the graph once.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ProductReachTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var database: DatabaseLayer { engine.database }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func make(_ specNode: GraphSpecNode) throws -> ObjectID {
        try specNode.findOrCreateMatchingNode().fromNode.requireID()
    }

    /// A step in the middle of a chain, named by `tag`, reading `inputs`.
    private func step(_ tag: String, reading inputs: [String: GraphSpecNode] = [:]) -> GraphSpecNode {
        GraphSpecNode(TreeMerger.self, properties: ["tag": tag],
                      inputs: inputs.isEmpty ? [:] : [TreeMerger.inputPort: inputs]).port("output")
    }

    private func product(at path: String, reading input: GraphSpecNode) -> GraphSpecNode {
        GraphSpecNode(OutputFile.self, properties: [OutputFile.pathProperty: path],
                      inputs: [OutputFile.inputPort: ["product": input]])
            .port(OutputFile.statusOutputPort)
    }

    private func entry(_ name: String, of tree: GraphSpecNode) -> GraphSpecNode {
        GraphSpecNode(TreeFile.self, properties: [TreeFile.nameProperty: name],
                      inputs: [TreeFile.treeInputPort: ["tree": tree]]).port(TreeFile.outputPort)
    }

    private func builder(reading formula: String) -> GraphSpecNode {
        GraphSpecNode(ProjectBuilder.self, properties: [:],
                      inputs: [ProjectBuilder.projectFileInputPort: [formula: .staticFile(at: formula)]])
            .port(ProjectBuilder.statusOutputPort)
    }

    /// A wire on one of a builder's dynamic ports, the way its own pass demands one.
    private func wire(_ sourceID: ObjectID, port fromPort: String, toBuilder builderID: ObjectID,
                      port toPort: String, named name: String) throws {
        try Wire.connectWire(database: database,
                             fromNodeID:   sourceID,
                             fromSymbolID: fromPort.asSymbolID(),
                             toNodeID:     builderID,
                             toSymbolID:   toPort.asSymbolID(),
                             name:         name.asSymbolID())
    }

    private func paths(_ products: [ProductReach.Product]) -> [String] {
        products.map(\.path)
    }

    // MARK: - The walk

    func test_aNodeFeedingTwoProductsNamesBothInPathOrder() throws {
        let source = try make(.staticFile(at: "input:/a.c"))
        let shared = step("shared", reading: ["a": .staticFile(at: "input:/a.c")])
        _ = try make(product(at: "output:/app/zeta", reading: step("z", reading: ["s": shared])))
        _ = try make(product(at: "output:/app/alpha", reading: shared))

        var reach = ProductReach(database: database)

        XCTAssertEqual(paths(reach.products(downstreamOf: source)), ["output:/app/alpha", "output:/app/zeta"])
        XCTAssertTrue(reach.products(downstreamOf: source).allSatisfy { $0.treeFolder == nil })
    }

    /// A node nothing under `output:` reads stops nothing, and says so with an empty list
    /// rather than with no answer.
    func test_aNodeFeedingNoProductHasNone() throws {
        let orphan = try make(step("orphan", reading: ["a": .staticFile(at: "input:/a.c")]))
        _ = try make(product(at: "output:/app/other", reading: .staticFile(at: "input:/b.c")))

        var reach = ProductReach(database: database)

        XCTAssertEqual(reach.products(downstreamOf: orphan), [])
    }

    /// A product holding a value was built from what the graph holds now, so a failure
    /// above it — a settings source read as nothing to add — did not stop it.
    func test_aProductThatWasBuiltIsNotStopped() throws {
        let failing = try make(.staticFile(at: "input:/machine.config"))
        _           = try make(.staticFile(at: "input:/a.c"))
        let merged  = step("merge", reading: ["machine": .staticFile(at: "input:/machine.config"),
                                              "source": .staticFile(at: "input:/a.c")])
        let mergedID = try make(merged)
        _ = try make(product(at: "output:/app/built", reading: merged))
        _ = try make(product(at: "output:/app/stopped", reading: step("other", reading: ["m": merged])))
        try database.node.select(nodeID: mergedID).writeToOutputPort("output", value: .value(try "bytes".intern()))

        var reach = ProductReach(database: database)

        XCTAssertEqual(paths(reach.products(downstreamOf: failing)), ["output:/app/stopped"])
    }

    /// A failing product is its own product.
    func test_aProductStopsItself() throws {
        let productID = try make(product(at: "output:/app/bin", reading: .staticFile(at: "input:/a.c")))

        var reach = ProductReach(database: database)

        XCTAssertEqual(paths(reach.products(downstreamOf: productID)), ["output:/app/bin"])
    }

    /// B-63. An entry of a tree product names its path and the tree's folder, so a report
    /// can put every entry of one tree under that folder.
    func test_aTreeProductsEntryNamesItsFolder() throws {
        let tree = step("actool", reading: ["catalog": .staticFile(at: "input:/Assets.xcassets")])
        let treeID = try make(tree)
        _ = try make(product(at: "output:/app/Res/en.lproj/Localizable.strings",
                             reading: entry("en.lproj/Localizable.strings", of: tree)))
        _ = try make(product(at: "output:/app/Res/Assets.car", reading: entry("Assets.car", of: tree)))

        var reach = ProductReach(database: database)

        XCTAssertEqual(reach.products(downstreamOf: treeID), [
            ProductReach.Product(path: "output:/app/Res/Assets.car", treeFolder: "output:/app/Res"),
            ProductReach.Product(path: "output:/app/Res/en.lproj/Localizable.strings", treeFolder: "output:/app/Res"),
        ])
    }

    /// A tree that failed has no manifest, so its entries were never made: what the walk
    /// reaches is the builder's `trees` wire, and the product is the tree's folder.
    func test_aTreeWhoseEntriesAreUnknownNamesItsFolder() throws {
        let treeID    = try make(step("actool", reading: ["catalog": .staticFile(at: "input:/Assets.xcassets")]))
        let builderID = try make(builder(reading: "input:/app/app.fmla"))
        try wire(treeID, port: "output", toBuilder: builderID, port: ProjectBuilder.treesInputPort,
                 named: "output:/app/Res")

        var reach = ProductReach(database: database)

        XCTAssertEqual(reach.products(downstreamOf: treeID),
                       [ProductReach.Product(path: "output:/app/Res", treeFolder: "output:/app/Res")])
    }

    /// A formula that cannot be read publishes none of its products, so its builder, and
    /// anything reaching it other than through `trees`, stops every product it holds — and
    /// the walk goes no further, where the project finder would reach every project.
    func test_aBuilderStopsEveryProductItHolds() throws {
        let formulaID = try make(.staticFile(at: "input:/app/app.fmla"))
        let builderID = try make(builder(reading: "input:/app/app.fmla"))
        let binary    = try make(product(at: "output:/app/bin", reading: .staticFile(at: "input:/a.c")))
        let tree      = try make(step("actool", reading: ["catalog": .staticFile(at: "input:/Assets.xcassets")]))
        try wire(binary, port: OutputFile.statusOutputPort, toBuilder: builderID,
                 port: ProjectBuilder.productInputPort, named: "output:/app/bin")
        try wire(tree, port: "output", toBuilder: builderID, port: ProjectBuilder.treesInputPort,
                 named: "output:/app/Res")

        var reach = ProductReach(database: database)

        XCTAssertEqual(reach.products(downstreamOf: formulaID), [
            ProductReach.Product(path: "output:/app/Res", treeFolder: "output:/app/Res"),
            ProductReach.Product(path: "output:/app/bin", treeFolder: nil),
        ])
    }

    /// The memo: twenty failing sources under one shared chain of three steps to one
    /// product. Each node is entered once — twenty sources, twenty readers, the three
    /// steps and the product — however many errors ask, where a walk per error would
    /// enter the shared chain twenty times.
    func test_aCascadeWalksTheSharedGraphOnce() throws {
        var sources: [ObjectID] = []
        var readers: [String: GraphSpecNode] = [:]
        for index in 0 ..< 20 {
            let path = "input:/src/\(index).c"
            sources.append(try make(.staticFile(at: path)))
            readers["reader \(index)"] = step("reader \(index)", reading: ["source": .staticFile(at: path)])
        }
        let chain = step("third", reading: ["in": step("second", reading: ["in": step("first", reading: readers)])])
        _ = try make(product(at: "output:/app/lib.a", reading: chain))

        var reach = ProductReach(database: database)
        for source in sources {
            XCTAssertEqual(paths(reach.products(downstreamOf: source)), ["output:/app/lib.a"])
        }

        XCTAssertEqual(reach.nodeVisits, 20 + 20 + 3 + 1)
    }

    /// The report's own use of it: every entry named through one walk, the folded several
    /// of one type through the union of what each reaches.
    func test_reportEntriesAreNamedThroughOneWalk() throws {
        let first  = try make(.staticFile(at: "input:/a.c"))
        let second = try make(.staticFile(at: "input:/b.c"))
        let shared = step("shared", reading: ["a": .staticFile(at: "input:/a.c"), "b": .staticFile(at: "input:/b.c")])
        _ = try make(product(at: "output:/app/bin", reading: shared))

        let reported: [(nodeIDs: [ObjectID], entry: ErrorReport.Entry)] = [
            ([first], ErrorReport.Entry(label: "a", items: [])),
            ([second], ErrorReport.Entry(label: "b", items: [])),
        ]
        var reach = ProductReach(database: database)
        let named = ErrorReport.namingProducts(of: reported, reach: &reach)

        XCTAssertEqual(named.map { paths($0.entry.products) }, [["output:/app/bin"], ["output:/app/bin"]])
        XCTAssertEqual(reach.nodeVisits, 4, "two sources, the shared step and the product")
    }

    // MARK: - Naming a product

    func test_aProductsPathAndATreeProductsFolderNameProducts() throws {
        _ = try make(product(at: "output:/app/bin", reading: .staticFile(at: "input:/a.c")))
        let tree      = try make(step("actool", reading: ["catalog": .staticFile(at: "input:/Assets.xcassets")]))
        let builderID = try make(builder(reading: "input:/app/app.fmla"))
        try wire(tree, port: "output", toBuilder: builderID, port: ProjectBuilder.treesInputPort,
                 named: "output:/app/Res")

        XCTAssertTrue(try ProductReach.isProduct("output:/app/bin", database: database))
        XCTAssertTrue(try ProductReach.isProduct("output:/app/Res", database: database))
        XCTAssertFalse(try ProductReach.isProduct("output:/app", database: database), "a folder holding products")
        XCTAssertFalse(try ProductReach.isProduct("output:/app/nothing", database: database))
        XCTAssertFalse(try ProductReach.isProduct("output:", database: database))
    }
}
