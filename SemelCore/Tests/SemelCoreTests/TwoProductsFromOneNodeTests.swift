//
//  TwoProductsFromOneNodeTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// Two products whose expressions render to the same spec are fed by one node, so the
/// builder asks that node's output port for two wires into one of its own ports, told
/// apart only by the wire's name. Both products have to be built.
///
/// The shape is IceCubesApp's: two app extensions with the same string catalog and no asset
/// catalog render the identical tree expression, so one node feeds both bundles and each
/// bundle's localizations depend on its own wire surviving alongside the other's.
final class TwoProductsFromOneNodeTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.startProcessingLoop()
    }

    override func tearDown() {
        // A loop left running would keep processing against the next test's globals.
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// The same sequence `FilePlugin.handlePush` runs per file.
    private func push(_ relativePath: String, contents: String) throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(
                Path(relativePath).deletingLastComponent ?? .empty, pinned: true)
        let fullPath = Path(Folder.inputFileSystemName) / Path(relativePath)
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(fullPath.string)')").findOrCreateMatchingNode()
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
        _ = try file.replaceContent(try contents.intern())
    }

    /// The node `FormulaFilePlugin` creates for a `.fmla` file it finds.
    private func makeProjectBuilder(formulaPath: String) throws -> NodeRecord {
        let (node, _) = try GraphSpecNode.parse(
            "ProjectBuilder(outputFolder: 'input:/repo', " +
            "projectFile: ['\(formulaPath)': StaticFile(path: '\(formulaPath)').output]).status"
        ).findOrCreateMatchingNode()
        return node
    }

    private func wires(into node: NodeRecord, port: String) throws -> [Wire] {
        try engine.database.wire.select(goingToNodeID: try node.requireID(),
                                        toSymbolID: port.asSymbolID())
    }

    /// One tree, built by the engine's own nodes — no toolchain, no Apple tools.
    private let sharedTree =
        "TreeBuilder(input: ['greeting.txt': StaticFile(path: 'input:/repo/greeting.txt').output]).files"

    // MARK: - The two products

    func test_twoTreeProductsFedByOneNodeAreBothBuilt() throws {
        try push("repo/greeting.txt", contents: "hello")
        try push("repo/semel.fmla", contents: """
            product 'A.bundle/' = \(sharedTree)
            product 'B.bundle/' = \(sharedTree)
            """)

        let builder = try makeProjectBuilder(formulaPath: "input:/repo/semel.fmla")
        engine.waitUntilIdleBlocking()

        let treeWires = try wires(into: builder, port: ProjectBuilder.treesInputPort)
        XCTAssertEqual(Set(treeWires.map(\.fromNodeID)).count, 1,
                       "precondition: both products are fed by one node")
        XCTAssertEqual(treeWires.map { $0.name.resolveSymbol() }.sorted(),
                       ["output:/repo/A.bundle", "output:/repo/B.bundle"],
                       "one tree wire per product, named by the product it feeds")
        XCTAssertEqual(try wires(into: builder, port: ProjectBuilder.productInputPort)
                           .map { $0.name.resolveSymbol() }.sorted(),
                       ["output:/repo/A.bundle/greeting.txt", "output:/repo/B.bundle/greeting.txt"],
                       "both bundles hold the tree's file")
    }
}
