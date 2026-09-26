//
//  AppPreludeTests.swift
//  SemelCLITests
//
//  B-108. HelloApp through `include 'swift'` and `include 'apple'`: the executable and the
//  Info.plist are the nodes the hand-written formula built, and the resources tree holds
//  the same compilers — found by pattern now, so its wires are named after each table.
//

@testable import SemelApple
@testable import SemelCore
@testable import SemelSwift
import SemelNodeKit
import XCTest

final class AppPreludeTests: XCTestCase {

    private let basePath = Path("input:/app")

    /// What the converter's formula for HelloKit provides: the product's trees.
    private let converterSpec = "SwiftFormulaConverter(path: 'input:/app/HelloKit', root: 'input:/app').formula"
    private let converterText = """
        func modules_HelloKit() = TreeMerger(input: ['HelloKit': Configuration(role: 'modules').output])
        func objects_HelloKit() = TreeBuilder(input: ['HelloKit.o': Configuration(role: 'objects').output])
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
                                     includeReader: { included[$0] })
    }

    /// `EndToEnd/Fixtures/swift/HelloApp/semel.fmla` before B-108.
    private let handWritten = """
        func settings(prefix) = ConfigFilter(prefix: prefix, input: ['config': StaticFile(path: <semel.config>).output]).output

        include SwiftFormulaConverter(path: <HelloKit>, root: <.>).formula

        func compiled() = SwiftCompiler(
            configuration: ['config': Configuration(moduleName: 'Hello', inherit: ['settings': settings(prefix: 'swift.compiler')]).output],
            inputFolder: ['folder0': Folder(path: <Sources>).manifest],
            moduleTrees: ['HelloKit': modules_HelloKit().files]
        )

        func assets() = AssetCatalogCompiler(
            configuration: ['config': Configuration(appIcon: 'AppIcon', inherit: ['settings': settings(prefix: 'apple.assetCatalogCompiler')]).output],
            catalogs: ['assets': Folder(path: <Assets.xcassets>).manifest]
        )

        product 'Hello.app/Hello' = SwiftLinker(
            configuration: ['config': Configuration(linkage: 'executable', outputName: 'Hello', inherit: ['settings': settings(prefix: 'swift.linker')]).output],
            input: ['Hello.o': compiled().object],
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

    func test_theExecutableAndInfoPlistAreTheNodesTheHandWrittenFormulaBuilt() throws {
        let expected = try parse(handWritten)
        let actual   = try parse(try withPreludes)

        for product in ["Hello.app/Hello", "Hello.app/Info.plist"] {
            XCTAssertEqual(try XCTUnwrap(actual[product]).asString(omitOutputPort: false),
                           try XCTUnwrap(expected[product]).asString(omitOutputPort: false),
                           product)
        }
    }

    func test_theResourcesTreeCompilesEachStringCatalogInTheFolder() throws {
        let resources = try XCTUnwrap(try parse(try withPreludes)["Hello.app/"])

        XCTAssertEqual(resources.typeName, "TreeMerger")
        let wires = try XCTUnwrap(resources.inputs.first?.wires)
        XCTAssertEqual(wires.map(\.name), ["assets", "Localizable"])
        XCTAssertEqual(wires.map(\.node.typeName), ["AssetCatalogCompiler", "StringCatalogCompiler"])
        XCTAssertEqual(wires[1].node.inputs.first { $0.portName == "catalog" }?.wires.map(\.name),
                       ["Localizable.xcstrings"])
    }
}
