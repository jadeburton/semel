//
//  AppPreludeTests.swift
//  SemelCLITests
//
//  B-108. HelloApp through `include 'swift'` and `include 'apple'`: one tree product, the
//  bundle, whose executable and Info.plist are the nodes the hand-written formula built as
//  products of their own, and whose resources tree holds the same compilers — found by
//  pattern now, so its wires are named after each table.
//

@testable import SemelApple
@testable import SemelCore
@testable import SemelSwift
import SemelNodeKit
import XCTest

final class AppPreludeTests: XCTestCase {

    private let basePath = Path("input:/app")

    /// The parser wires a file's mode where the file's source publishes one, which it
    /// learns from the registered types — the engine's and the linker's.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try BuildEngine.registerTypes()
        try SemelSwift.register()
    }

    /// What the converter's formula for HelloKit provides: the product's trees.
    private let converterSpec = "SwiftFormulaConverter(path: 'input:/app/HelloKit', root: 'input:/app').formula"
    private let converterText = """
        func modules_HelloKit() = TreeMerger(input: ['HelloKit': SettingsLiteral(role: 'modules').output])
        func objects_HelloKit() = TreeBuilder(input: ['HelloKit.o': SettingsLiteral(role: 'objects').output])
        """

    private func parse(_ formula: String) throws -> [String: GraphSpecNode] {
        let included = [
            converterSpec: converterText,
            FormulaPrelude.spec(forIncludeNamed: "swift").asString(omitOutputPort: false):
                FormulaPrelude.publishedText(namespace: "swift", text: SemelSwift.prelude),
            FormulaPrelude.spec(forIncludeNamed: "apple").asString(omitOutputPort: false):
                FormulaPrelude.publishedText(namespace: "apple", text: SemelApple.prelude),
        ]
        return try FormulaFile.parse(formula, basePath: basePath,
                                     wildcardExpander: { pattern in
                                         pattern == "input:/app/Resources/*.xcstrings"
                                             ? ["input:/app/Resources/Localizable.xcstrings"] : []
                                     },
                                     includeReader: { included[$0.asString(omitOutputPort: false)] })
    }

    /// `EndToEnd/Fixtures/swift/HelloApp/semel.fmla` before B-108, over the two files B-109
    /// gave it: the project's choices laid over the machine's facts; with the app's
    /// Objective-C compiled and linked, and its bridging header imported, since B-77; its
    /// icon an Icon Composer `.icon` compiled with the catalog since B-89.
    private let handWritten = """
        func settings(prefix) = ConfigFilter(prefix: prefix, input: ['config': ConfigMerger(base: ['machine': StaticFile(path: <semel.machine.config>).output], override: ['project': StaticFile(path: <semel.config>).output]).output]).output

        func objectiveC(prefix) = ConfigMerger(base: ['settings': settings(prefix: prefix)], override: ['literals': SettingsLiteral(modules: 'true', objectiveCARC: 'true').output]).output

        include SwiftFormulaConverter(path: <HelloKit>, root: <.>).formula

        func compiled() = SwiftCompiler(
            configuration: ['config': ConfigMerger(base: ['settings': settings(prefix: 'swift.compiler')], override: ['literals': SettingsLiteral(moduleName: 'Hello').output]).output],
            inputFolder: ['folder0': Folder(path: <Sources>).manifest],
            moduleTrees: ['HelloKit': modules_HelloKit().files],
            bridgingHeader: ['ObjC/Hello-Bridging-Header.h': StaticFile(path: <ObjC/Hello-Bridging-Header.h>).output],
            headerTrees: ['Hello': TreeBuilder(input: ['ObjC/HLOGreeter.h': StaticFile(path: <ObjC/HLOGreeter.h>).output]).files]
        )

        func greeter() = ClangCompiler(
            configuration: ['config': objectiveC(prefix: 'clang.compiler')],
            input: ['input:/app/ObjC/HLOGreeter.m.p': ClangPreprocessor(
                configuration: ['config': objectiveC(prefix: 'clang.preprocessor')],
                input: ['input:/app/ObjC/HLOGreeter.m': StaticFile(path: <ObjC/HLOGreeter.m>)],
                headerFolders: ['ObjC': Folder(path: <ObjC>).manifest]
            ).output]
        ).output

        func assets() = AssetCatalogCompiler(
            configuration: ['config': ConfigMerger(base: ['settings': settings(prefix: 'apple.assetCatalogCompiler')], override: ['literals': SettingsLiteral(appIcon: 'AppIcon').output]).output],
            catalogs: ['assets': Folder(path: <Assets.xcassets>).manifest, 'icon': Folder(path: <AppIcon.icon>).manifest]
        )

        product 'Hello.app/Hello' = SwiftLinker(
            configuration: ['config': ConfigMerger(base: ['settings': settings(prefix: 'swift.linker')], override: ['literals': SettingsLiteral(linkage: 'executable', outputName: 'Hello').output]).output],
            input: ['Hello.o': compiled().object, 'HLOGreeter.m.o': greeter()],
            objectTrees: ['HelloKit': objects_HelloKit().files]
        ).output

        product 'Hello.app/Info.plist' = InfoPlistBuilder(
            base: ['base': StaticFile(path: <Info.plist>).output],
            partials: ['assets': assets().partialInfoPlist]
        ).plist
        """

    private var withPreludes: String {
        get throws {
            try String(contentsOfFile: #filePath.replacingOccurrences(of: "semel/Tests/AppPreludeTests.swift",
                                                                      with: "EndToEnd/Fixtures/swift/HelloApp/semel.fmla"),
                       encoding: .utf8)
        }
    }

    /// The bundle is one product, a merger of the single files' tree and the resources'.
    private var bundle: GraphSpecNode {
        get throws {
            let products = try parse(try withPreludes)
            XCTAssertEqual(products.keys.sorted(), ["Hello.app/"], "the whole bundle is one tree product")
            return try XCTUnwrap(products["Hello.app/"])
        }
    }

    private func wire(_ name: String, of node: GraphSpecNode, port: String = "input") throws -> GraphSpecNode {
        try XCTUnwrap(node.inputs.first { $0.portName == port }?.wires.first { $0.name == name }?.node,
                      "\(node.typeName) has no wire '\(name)' on '\(port)'")
    }

    func test_theExecutableAndInfoPlistAreTheNodesTheHandWrittenFormulaBuilt() throws {
        let expected = try parse(handWritten)
        let files    = try wire("files", of: try bundle)

        for (entry, product) in [("Hello", "Hello.app/Hello"), ("Info.plist", "Hello.app/Info.plist")] {
            XCTAssertEqual(try wire(entry, of: files).asString(omitOutputPort: false),
                           try XCTUnwrap(expected[product]).asString(omitOutputPort: false),
                           product)
        }
    }

    /// B-108. `apple.bundle`'s rendered spec: the executable, `Info.plist` and `PkgInfo`
    /// named as bundle entries, each file whose source publishes a mode wired to it — the
    /// linker's, which is what keeps the executable launchable, and the pushed `PkgInfo`'s
    /// — and the resources merged beside them at the root.
    func test_theBundleIsTheSingleFilesAndTheResourcesAsOneTree() throws {
        let bundle = try bundle

        XCTAssertEqual(bundle.typeName, "TreeMerger")
        XCTAssertEqual(bundle.inputs.first?.wires.map(\.name), ["files", "resources"])
        let files = try wire("files", of: bundle)
        XCTAssertEqual(files.typeName, "TreeBuilder")
        XCTAssertEqual(files.inputs.first { $0.portName == "input" }?.wires.map(\.name), ["Hello", "Info.plist", "PkgInfo"])
        XCTAssertEqual(try wire("PkgInfo", of: files).asString(omitOutputPort: false),
                       "StaticFile(path: 'input:/app/PkgInfo').output")

        let modes = try XCTUnwrap(files.inputs.first { $0.portName == FileMetadata.portName })
        XCTAssertEqual(modes.wires.map(\.name), ["Hello", "PkgInfo"], "a plist builder publishes no mode")
        XCTAssertEqual(try wire("Hello", of: files, port: FileMetadata.portName),
                       try wire("Hello", of: files).port(FileMetadata.portName))
        XCTAssertEqual(try wire("Hello", of: files).typeName, "SwiftLinker")
    }

    func test_theResourcesTreeCompilesEachStringCatalogInTheFolder() throws {
        let resources = try wire("catalogs", of: try wire("resources", of: try bundle))

        XCTAssertEqual(resources.typeName, "TreeMerger")
        let wires = try XCTUnwrap(resources.inputs.first?.wires)
        XCTAssertEqual(wires.map(\.name), ["assets", "Localizable"])
        XCTAssertEqual(wires.map(\.node.typeName), ["AssetCatalogCompiler", "StringCatalogCompiler"])
        XCTAssertEqual(wires[1].node.inputs.first { $0.portName == "catalog" }?.wires.map(\.name),
                       ["Localizable.xcstrings"])
    }

    /// B-77. Beside the catalogs, the xib compiled by ibtool, keyed by its place in the
    /// bundle, which is where the nib lands.
    func test_theResourcesTreeHoldsTheCompiledXibUnderItsLanguageFolder() throws {
        let interface = try wire("interface", of: try wire("resources", of: try bundle))

        XCTAssertEqual(interface.typeName, "IBToolCompiler")
        XCTAssertEqual(try wire("Base.lproj/Card.xib", of: interface, port: "document").asString(omitOutputPort: false),
                       "StaticFile(path: 'input:/app/Interface/Base.lproj/Card.xib').output")
    }
}
