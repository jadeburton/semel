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
    /// processing one needs a graph database holding the builder and its ports, and
    /// nothing else. Without this the class only passed after another suite had left a
    /// database behind.
    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = try DatabaseLayer()
    }

    // MARK: - Helpers

    /// A builder as `createNode` leaves one: a row, and a row for every port its type
    /// declares. The builder reads its own `products` port, and a node missing that row is
    /// a damaged graph rather than a fresh one.
    private func makeBuilderNode(properties: [String: String]) throws -> NodeRecord {
        var node = NodeRecord(parentNodeID: nil, kind: ProjectBuilder.kind, name: nil,
                              properties: properties, scheduled: false, identity: nil)
        node.id = try DatabaseLayer.shared.node.insert(node)
        try node.writePendingToAllOutputsOfNode()
        return node
    }

    /// One product, wired to a node that needs nothing — the product's shape is
    /// irrelevant here, only the output path it is wrapped in.
    private let oneProduct = """
        product 'MyProduct' =
            SettingsLiteral(moduleName: 'X').output
        """

    private func productPaths(projectFile: String,
                              properties: [String: String] = [:],
                              formula: String? = nil) throws -> [String] {
        let builder = try ProjectBuilder(thisNode: try makeBuilderNode(properties: properties))
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
                                     formula: "product 'repo' =\n    SettingsLiteral(moduleName: 'X').output")
        let inner = try productPaths(projectFile: "input:/repo/Core",
                                     properties: ["outputFolder": "input:/repo/Core"],
                                     formula: "product 'Core' =\n    SettingsLiteral(moduleName: 'X').output")

        XCTAssertEqual(outer, ["output:/repo/repo"])
        XCTAssertEqual(inner, ["output:/repo/Core/Core"])
        XCTAssertFalse(inner[0].hasPrefix(outer[0] + "/"),
                       "the outer product must not be a folder on the inner product's path")
    }

    // MARK: - A formula that includes another (B-10)

    /// The included node here is a SettingsLiteral, so the spec parses without a real
    /// converter; in a Swift build it is `SwiftFormulaConverter(path: <.>).formula`.
    private let includedNode = "SettingsLiteral(role: 'generated').output"

    private func process(formula: String,
                         includes: [String: NodeValue] = [:]) throws -> ProcessOutput {
        let node = try makeBuilderNode(properties: ["outputFolder": "input:/repo"])
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

        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.includesInputPort]?.rendered, [includedNode: includedNode])
        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.productInputPort], [:])
    }

    /// Later pass: the text has arrived, and the included products are published beside
    /// the formula file — the formula's folder, not somewhere the included node chose.
    func test_publishesTheIncludedProductsBesideTheFormula() throws {
        let included = "product 'libX.a' = SettingsLiteral(moduleName: 'X').output"

        let output = try process(formula: "include \(includedNode)",
                                 includes: [includedNode: .value(try included.intern())])

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]).keys.sorted(),
                       ["output:/repo/libX.a"])
    }

    /// An included text may include in turn — a project's generated formula includes each
    /// package's. The nested include is wired once the outer text has arrived, and the
    /// nested text's funcs are callable from the outer text once both are there.
    func test_followsAnIncludeInsideAnIncludedText() throws {
        let innerNode = "SettingsLiteral(role: 'package').output"
        let outer = "include \(innerNode)\nproduct 'App' = kit().output"
        let inner = "func kit() = SettingsLiteral(moduleName: 'Kit')"

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
        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.includesInputPort]?.rendered, [includedNode: includedNode])
    }

    // MARK: - projectRoot stamping (B-49)

    /// Every node a product is built through learns the project's root, so its cache key
    /// can name its inputs relative to it. A `StaticFile` is not built through: it is
    /// the pushed file itself, shared by every project that reads it, and stamping it
    /// would split it into one node per project.
    func test_stampsTheProjectRootOnEveryCacheableNodeOfAProduct() throws {
        let output = try process(formula:
            "product 'x' = SampleTool(configuration: ['c': StaticFile(path: 'input:/repo/c').output]).output")

        let spec = try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]?["output:/repo/x"]).asString(omitOutputPort: false)
        XCTAssertTrue(spec.contains("SampleTool(projectRoot: 'input:/repo', configuration: ["), spec)
        XCTAssertTrue(spec.contains("StaticFile(path: 'input:/repo/c')"), spec)
        XCTAssertFalse(spec.contains("StaticFile(path: 'input:/repo/c', projectRoot"), spec)
        XCTAssertTrue(spec.contains("OutputFile(path: 'output:/repo/x', input: ["), spec)
    }

    // MARK: - Nested source folders (B-108)

    private func manifest(_ path: String, files: [String] = [], folders: [String] = []) throws -> NodeValue {
        let entries = files.map { FolderManifestEntry(name: $0, isFolder: false, isPinned: true) }
                    + folders.map { FolderManifestEntry(name: $0, isFolder: true, isPinned: true) }
        return .value(try FolderManifest(baseFolderPath: path, entries: entries).toJSON().intern())
    }

    private func process(formula: String, folders: [String: NodeValue]) throws -> ProcessOutput {
        let node = try makeBuilderNode(properties: ["outputFolder": "input:/repo"])
        return try ProjectBuilder(thisNode: node).process(input: ProcessInput(inputValues: [
            ProjectBuilder.projectFileInputPort:  ["input:/repo/semel.fmla": .value(try formula.intern())],
            ProjectBuilder.productInputPort:      [:],
            ProjectBuilder.foldersInputPort:      folders,
            ProjectBuilder.graphImportsInputPort: [:],
            ProjectBuilder.includesInputPort:     [:],
        ]))
    }

    /// The paths a product's for-each reached, read back from the `StaticFile`s it wired.
    private func sourcePaths(_ output: ProcessOutput) throws -> [String] {
        let spec = try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]?["output:/repo/x"])
        return (spec.inputs.first?.wires.first?.node.inputs.first?.wires ?? []).map(\.name)
    }

    private let recursiveFormula = """
        product 'x' = SampleTool(configuration: [{f: <src/**/*.c>} "%%f%%": StaticFile(path: f).output]).output
        """

    /// The tree the builder walks: `src` holds a file and two folders, one of them hidden;
    /// `src/lib` holds a file and a folder, which holds one more.
    private func sourceTree() throws -> [String: NodeValue] {
        [
            "input:/repo/src":          try manifest("input:/repo/src", files: ["main.c", "notes.txt"], folders: ["lib", ".cache"]),
            "input:/repo/src/lib":      try manifest("input:/repo/src/lib", files: ["util.c", ".hidden.c"], folders: ["deep"]),
            "input:/repo/src/lib/deep": try manifest("input:/repo/src/lib/deep", files: ["core.c"]),
        ]
    }

    /// Level by level: each pass demands the subfolders the manifests so far reveal and
    /// publishes nothing while any of them is on its way, so a product never links a
    /// partial file set. A hidden folder is not entered.
    func test_aDoubleStarPatternDemandsItsSubfoldersLevelByLevel() throws {
        let tree = try sourceTree()

        let first = try process(formula: recursiveFormula, folders: [:])
        XCTAssertEqual(first.inputWireSpecs[ProjectBuilder.foldersInputPort]?.keys.sorted(), ["input:/repo/src"])
        XCTAssertEqual(first.inputWireSpecs[ProjectBuilder.productInputPort], [:])

        let second = try process(formula: recursiveFormula, folders: ["input:/repo/src": try XCTUnwrap(tree["input:/repo/src"])])
        XCTAssertEqual(second.inputWireSpecs[ProjectBuilder.foldersInputPort]?.rendered,
                       ["input:/repo/src":     "Folder(path: 'input:/repo/src').manifest",
                        "input:/repo/src/lib": "Folder(path: 'input:/repo/src/lib').manifest"])
        XCTAssertEqual(second.inputWireSpecs[ProjectBuilder.productInputPort], [:], "src/lib is still on its way")

        let third = try process(formula: recursiveFormula, folders: tree.filter { $0.key != "input:/repo/src/lib/deep" })
        XCTAssertEqual(third.inputWireSpecs[ProjectBuilder.foldersInputPort]?.keys.sorted(),
                       ["input:/repo/src", "input:/repo/src/lib", "input:/repo/src/lib/deep"])
        XCTAssertEqual(third.inputWireSpecs[ProjectBuilder.productInputPort], [:], "src/lib/deep is still on its way")
    }

    /// Once the walk has arrived: every `.c` at any depth, `src` itself included, sorted,
    /// and no hidden file or anything in a hidden folder.
    func test_aDoubleStarPatternExpandsOverTheWholeTreeOnceItHasArrived() throws {
        let output = try process(formula: recursiveFormula, folders: try sourceTree())

        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.foldersInputPort]?.keys.sorted(),
                       ["input:/repo/src", "input:/repo/src/lib", "input:/repo/src/lib/deep"])
        XCTAssertEqual(try sourcePaths(output),
                       ["input:/repo/src/lib/deep/core.c", "input:/repo/src/lib/util.c", "input:/repo/src/main.c"])
    }

    /// `*` stays one level: the same tree under `src/*.c` is `src`'s own `.c` files, and
    /// no subfolder is demanded.
    func test_aSingleStarPatternReadsOneFolderAndDemandsNoOther() throws {
        let output = try process(formula: recursiveFormula.replacingOccurrences(of: "src/**/*.c", with: "src/*.c"),
                                 folders: try sourceTree())

        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.foldersInputPort]?.keys.sorted(), ["input:/repo/src"])
        XCTAssertEqual(try sourcePaths(output), ["input:/repo/src/main.c"])
    }

    /// A trailing `**` is every file below, whatever its name.
    func test_aTrailingDoubleStarIsEveryFileBelow() throws {
        let output = try process(formula: recursiveFormula.replacingOccurrences(of: "src/**/*.c", with: "src/**"),
                                 folders: try sourceTree())

        XCTAssertEqual(try sourcePaths(output),
                       ["input:/repo/src/lib/deep/core.c", "input:/repo/src/lib/util.c",
                        "input:/repo/src/main.c", "input:/repo/src/notes.txt"])
    }

    /// `except` goes through the same expander, walk included: a subfolder left out by a
    /// pattern of its own.
    func test_exceptWithADoubleStarLeavesOutASubfolder() throws {
        let output = try process(formula: recursiveFormula.replacingOccurrences(of: "<src/**/*.c>",
                                                                                with: "<src/**/*.c> except <src/lib/deep/**>"),
                                 folders: try sourceTree())

        XCTAssertEqual(try sourcePaths(output), ["input:/repo/src/lib/util.c", "input:/repo/src/main.c"])
    }

    // MARK: - Tree products (B-63)

    /// The tree-valued node here is a TreeMerger, so the spec parses without a real
    /// resource compiler; in an app build it is `AssetCatalogCompiler(...).files`.
    private let treeNode = "TreeMerger(under: 'catalog').files"

    /// `treeNode` as it is wired and embedded downstream: TreeMerger has a static input
    /// port, so it is cacheable and carries the project's root.
    private let stampedTreeNode = "TreeMerger(projectRoot: 'input:/repo', under: 'catalog').files"

    private func process(formula: String, trees: [String: NodeValue]) throws -> ProcessOutput {
        let node = try makeBuilderNode(properties: ["outputFolder": "input:/repo"])
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

        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.treesInputPort]?.rendered, ["output:/repo/Hello.app": stampedTreeNode])
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
        let spec = try XCTUnwrap(products["output:/repo/Hello.app/en.lproj/Localizable.strings"]).asString(omitOutputPort: false)
        XCTAssertTrue(spec.contains("TreeFile(name: 'en.lproj/Localizable.strings'"), spec)
        XCTAssertTrue(spec.contains(stampedTreeNode), spec)
        XCTAssertTrue(spec.contains("fileMetadata"), "the entry's mode reaches the output file: \(spec)")
    }

    /// A plain product and a tree product share a folder — the executable beside the
    /// compiled resources is the whole point.
    func test_aTreeProductAndAPlainProductShareAFolder() throws {
        let output = try process(formula: """
            product 'Hello.app/Hello' = SettingsLiteral(role: 'exe').output
            product 'Hello.app/' = \(treeNode)
            """, trees: ["output:/repo/Hello.app": try tree(["Assets.car"])])

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]).keys.sorted(),
                       ["output:/repo/Hello.app/Assets.car", "output:/repo/Hello.app/Hello"])
    }

    /// Two products at one path would be two nodes with one name in one folder. The
    /// formula is wrong, and the builder says so rather than letting one win.
    func test_twoProductsAtOnePathAreAnError() throws {
        XCTAssertThrowsError(try process(formula: """
            product 'Hello.app/Assets.car' = SettingsLiteral(role: 'exe').output
            product 'Hello.app/' = \(treeNode)
            """, trees: ["output:/repo/Hello.app": try tree(["Assets.car"])])) { error in
            XCTAssertTrue("\(error)".contains("Hello.app/Assets.car"), "\(error)")
        }
    }
}
