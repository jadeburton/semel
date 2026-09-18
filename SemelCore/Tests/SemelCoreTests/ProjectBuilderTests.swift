//
//  ProjectBuilderTests.swift
//  semel_tests
//
//  Where a project's products land in the output file system. The rule is not obvious
//  because the two ProjectFinder plugins wire their projectFile port differently: a
//  Swift package is keyed by its *folder*, a .fmla project by the *file*.
//

@testable import SemelCore
import XCTest
import SemelNodeKit

final class ProjectBuilderTests: SemelCoreTestCase {

    /// A builder reads its own `products` port to report what appeared or disappeared, so
    /// processing one needs a graph database — an empty one; nothing here is persisted.
    /// Without this the class only passed after another suite had left a database behind.
    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = try DatabaseLayer()
    }

    // MARK: - Helpers

    /// One product, wired to a node that needs nothing — the product's shape is
    /// irrelevant here, only the output path it is wrapped in.
    private let oneProduct = """
        product 'MyProduct' =
            Configuration(moduleName: 'X').output
        """

    private func productPaths(projectFile: String,
                              properties: [String: String] = [:],
                              formula: String? = nil) throws -> [String] {
        let node = NodeRecord(id: 1, kind: ProjectBuilder.kind, name: nil,
                        properties: properties, scheduled: false, graphSpec: nil)
        let builder = try ProjectBuilder(thisNode: node)
        let input = ProcessInput(inputValues: [
            ProjectBuilder.projectFileInputPort:  [projectFile: .value(try (formula ?? oneProduct).intern())],
            ProjectBuilder.productInputPort:      [:],
            ProjectBuilder.foldersInputPort:      [:],
            ProjectBuilder.graphImportsInputPort: [:],
        ])
        let output = try builder.process(input: input)
        return try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]).keys.sorted()
    }

    // MARK: - Product placement

    /// SwiftPackagePlugin keys the projectFile wire by the package *folder*, so deriving
    /// the output location from the wire key's parent put products one level too high:
    /// the root package's `semel` product landed on `output:/swift/semel`,
    /// the very folder holding the nested packages' products.
    func test_placesAPackageProductInsideThePackageFolder() throws {
        let paths = try productPaths(projectFile: "input:/swift/semel",
                                     properties: ["outputFolder": "input:/swift/semel"])

        XCTAssertEqual(paths, ["output:/swift/semel/MyProduct"])
    }

    /// FormulaFilePlugin keys the wire by the .fmla file itself, whose containing folder
    /// is the project's own directory — so this placement is unchanged.
    func test_placesAFormulaFileProductBesideTheFormulaFile() throws {
        let paths = try productPaths(projectFile: "input:/proj/build.fmla",
                                     properties: ["outputFolder": "input:/proj"])

        XCTAssertEqual(paths, ["output:/proj/MyProduct"])
    }

    /// A node created before the property existed must keep working rather than write its
    /// products to the file-system root.
    func test_fallsBackToTheProjectFilesFolderWhenNoOutputFolderIsSet() throws {
        let paths = try productPaths(projectFile: "input:/proj/build.fmla")

        XCTAssertEqual(paths, ["output:/proj/MyProduct"])
    }

    /// Two packages nested one inside the other are the case that collided. Their
    /// products must land on distinct paths, and neither may be a prefix of the other.
    func test_nestedPackagesProduceNonCollidingProductPaths() throws {
        let outer = try productPaths(projectFile: "input:/repo",
                                     properties: ["outputFolder": "input:/repo"],
                                     formula: "product 'repo' =\n    Configuration(moduleName: 'X').output")
        let inner = try productPaths(projectFile: "input:/repo/Core",
                                     properties: ["outputFolder": "input:/repo/Core"],
                                     formula: "product 'Core' =\n    Configuration(moduleName: 'X').output")

        XCTAssertEqual(outer, ["output:/repo/repo"])
        XCTAssertEqual(inner, ["output:/repo/Core/Core"])
        XCTAssertFalse(inner[0].hasPrefix(outer[0] + "/"),
                       "the outer product must not be a folder on the inner product's path")
    }

    // MARK: - A formula that includes another (B-10)

    /// The included node here is a Configuration, so the spec parses without a real
    /// converter; in a Swift build it is `SwiftFormulaConverter(path: <.>).formula`.
    private let includedNode = "Configuration(role: 'generated').output"

    private func process(formula: String,
                         includes: [String: NodeValue] = [:]) throws -> ProcessOutput {
        let node = NodeRecord(id: 1, kind: ProjectBuilder.kind, name: nil,
                              properties: ["outputFolder": "input:/repo"], scheduled: false, graphSpec: nil)
        return try ProjectBuilder(thisNode: node).process(input: ProcessInput(inputValues: [
            ProjectBuilder.projectFileInputPort:  ["input:/repo/semel.fmla": .value(try formula.intern())],
            ProjectBuilder.productInputPort:      [:],
            ProjectBuilder.foldersInputPort:      [:],
            ProjectBuilder.graphImportsInputPort: [:],
            ProjectBuilder.includesInputPort:     includes,
        ]))
    }

    /// First pass: the included text is not on the wire yet, so the builder wires the node
    /// the include names — keyed by its own spec — and publishes nothing.
    func test_wiresTheIncludedNodeBeforePublishingAnything() throws {
        let output = try process(formula: "include \(includedNode)")

        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.includesInputPort], [includedNode: includedNode])
        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.productInputPort], [:])
    }

    /// Later pass: the text has arrived, and the included products are published beside
    /// the formula file — the formula's folder, not somewhere the included node chose.
    func test_publishesTheIncludedProductsBesideTheFormula() throws {
        let included = "product 'libX.a' = Configuration(moduleName: 'X').output"

        let output = try process(formula: "include \(includedNode)",
                                 includes: [includedNode: .value(try included.intern())])

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]).keys.sorted(),
                       ["output:/repo/libX.a"])
    }

    /// An included text may include in turn — a project's generated formula includes each
    /// package's. The nested include is wired once the outer text has arrived, and the
    /// nested text's funcs are callable from the outer text once both are there.
    func test_followsAnIncludeInsideAnIncludedText() throws {
        let innerNode = "Configuration(role: 'package').output"
        let outer = "include \(innerNode)\nproduct 'App' = kit().output"
        let inner = "func kit() = Configuration(moduleName: 'Kit')"

        let firstPass = try process(formula: "include \(includedNode)",
                                    includes: [includedNode: .value(try outer.intern())])
        XCTAssertEqual(firstPass.inputWireSpecs[ProjectBuilder.includesInputPort]?.keys.sorted(),
                       [innerNode, includedNode].sorted(), "the nested include is wired")
        XCTAssertEqual(firstPass.inputWireSpecs[ProjectBuilder.productInputPort], [:])

        let secondPass = try process(formula: "include \(includedNode)",
                                     includes: [includedNode: .value(try outer.intern()),
                                                innerNode: .value(try inner.intern())])
        XCTAssertEqual(try XCTUnwrap(secondPass.inputWireSpecs[ProjectBuilder.productInputPort]).keys.sorted(),
                       ["output:/repo/App"])
    }

    /// A pending value on the wire — the node is still waiting on its own inputs — is the
    /// same as no value: nothing is published, and the wire is kept.
    func test_aPendingIncludePublishesNothingYet() throws {
        let output = try process(formula: "include \(includedNode)",
                                 includes: [includedNode: .noValue(reason: .pending)])

        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.productInputPort], [:])
        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.includesInputPort], [includedNode: includedNode])
    }

    // MARK: - projectRoot stamping (B-49)

    /// Every node a product is built through learns the project's root, so its cache key
    /// can name its inputs relative to it. A `StaticFile` is not built through: it is
    /// the pushed file itself, shared by every project that reads it, and stamping it
    /// would split it into one node per project.
    func test_stampsTheProjectRootOnEveryCacheableNodeOfAProduct() throws {
        let output = try process(formula:
            "product 'x' = SampleTool(configuration: ['c': StaticFile(path: 'input:/repo/c').output]).output")

        let spec = try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]?["output:/repo/x"])
        XCTAssertTrue(spec.contains("SampleTool(projectRoot: 'input:/repo', configuration: ["), spec)
        XCTAssertTrue(spec.contains("StaticFile(path: 'input:/repo/c')"), spec)
        XCTAssertFalse(spec.contains("StaticFile(path: 'input:/repo/c', projectRoot"), spec)
        XCTAssertTrue(spec.contains("OutputFile(path: 'output:/repo/x', input: ["), spec)
    }

    // MARK: - Tree products (B-63)

    /// The tree-valued node here is a Configuration, so the spec parses without a real
    /// resource compiler; in an app build it is `AssetCatalogCompiler(...).files`.
    private let treeNode = "Configuration(role: 'catalog').output"

    /// `treeNode` as it is wired and embedded downstream: Configuration has a static input
    /// port, so it is cacheable and carries the project's root.
    private let stampedTreeNode = "Configuration(projectRoot: 'input:/repo', role: 'catalog').output"

    private func process(formula: String, trees: [String: NodeValue]) throws -> ProcessOutput {
        let node = NodeRecord(id: 1, kind: ProjectBuilder.kind, name: nil,
                              properties: ["outputFolder": "input:/repo"], scheduled: false, graphSpec: nil)
        return try ProjectBuilder(thisNode: node).process(input: ProcessInput(inputValues: [
            ProjectBuilder.projectFileInputPort:  ["input:/repo/semel.fmla": .value(try formula.intern())],
            ProjectBuilder.productInputPort:      [:],
            ProjectBuilder.foldersInputPort:      [:],
            ProjectBuilder.treesInputPort:        trees,
            ProjectBuilder.graphImportsInputPort: [:],
            ProjectBuilder.includesInputPort:     [:],
        ]))
    }

    private func tree(_ paths: [String]) throws -> NodeValue {
        let entries = try paths.map { TreeManifestEntry(path: $0, hash: try $0.intern(), mode: 0o644) }
        return .value(try TreeManifest(entries: entries).toJSON().intern())
    }

    /// First pass: the tree's files are decided by the node that makes them, so the
    /// builder wires the expression — keyed by the product folder — and publishes nothing
    /// for it yet, as it does for a wildcard before the folder manifest arrives.
    func test_aTreeProductWiresItsTreeBeforePublishingAnything() throws {
        let output = try process(formula: "product 'Hello.app/' = \(treeNode)", trees: [:])

        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.treesInputPort], ["output:/repo/Hello.app": stampedTreeNode])
        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.productInputPort], [:])
    }

    /// Later pass: every entry of the tree is a product under the folder, each an
    /// `OutputFile` wrapping a `TreeFile` that picks the entry out of the same tree.
    func test_aTreeProductPublishesOneOutputFilePerEntry() throws {
        let output = try process(formula: "product 'Hello.app/' = \(treeNode)",
                                 trees: ["output:/repo/Hello.app": try tree(["Assets.car", "en.lproj/Localizable.strings"])])

        let products = try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort])
        XCTAssertEqual(products.keys.sorted(),
                       ["output:/repo/Hello.app/Assets.car", "output:/repo/Hello.app/en.lproj/Localizable.strings"])
        let spec = try XCTUnwrap(products["output:/repo/Hello.app/en.lproj/Localizable.strings"])
        XCTAssertTrue(spec.contains("TreeFile(name: 'en.lproj/Localizable.strings'"), spec)
        XCTAssertTrue(spec.contains(stampedTreeNode), spec)
        XCTAssertTrue(spec.contains("fileMetadata"), "the entry's mode reaches the output file: \(spec)")
    }

    /// A plain product and a tree product share a folder — the executable beside the
    /// compiled resources is the whole point.
    func test_aTreeProductAndAPlainProductShareAFolder() throws {
        let output = try process(formula: """
            product 'Hello.app/Hello' = Configuration(role: 'exe').output
            product 'Hello.app/' = \(treeNode)
            """, trees: ["output:/repo/Hello.app": try tree(["Assets.car"])])

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]).keys.sorted(),
                       ["output:/repo/Hello.app/Assets.car", "output:/repo/Hello.app/Hello"])
    }

    /// Two products at one path would be two nodes with one name in one folder. The
    /// formula is wrong, and the builder says so rather than letting one win.
    func test_twoProductsAtOnePathAreAnError() throws {
        XCTAssertThrowsError(try process(formula: """
            product 'Hello.app/Assets.car' = Configuration(role: 'exe').output
            product 'Hello.app/' = \(treeNode)
            """, trees: ["output:/repo/Hello.app": try tree(["Assets.car"])])) { error in
            XCTAssertTrue("\(error)".contains("Hello.app/Assets.car"), "\(error)")
        }
    }
}
