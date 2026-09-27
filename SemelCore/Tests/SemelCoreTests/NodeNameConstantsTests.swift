//
//  NodeNameConstantsTests.swift
//  SemelCore
//
//  B-115. A toolchain builds trees for the engine's file-system and settings nodes by
//  name, from constants in the node kit, because it cannot import the types. Those
//  constants are an interface, and this is what keeps them true to the types.
//

@testable import SemelCore
import SemelNodeKit
import XCTest

final class NodeNameConstantsTests: SemelCoreTestCase {

    func test_theFileSystemNodeNamesAreTheTypes() {
        XCTAssertEqual(FileSystemNodes.staticFileTypeName, String(describing: StaticFile.self))
        XCTAssertEqual(FileSystemNodes.staticFileOutputPort, StaticFile.outputPort)
        XCTAssertEqual(FileSystemNodes.folderTypeName, String(describing: Folder.self))
        XCTAssertEqual(FileSystemNodes.folderManifestPort, Folder.folderManifestOutputPort)
        XCTAssertTrue(StaticFile.descriptor.outputPorts.contains(FileSystemNodes.staticFileOutputPort))
        XCTAssertTrue(Folder.descriptor.outputPorts.contains(FileSystemNodes.folderManifestPort))
    }

    func test_theSettingsNodeNamesAreTheTypes() {
        XCTAssertEqual(SettingsNodes.settingsLiteralTypeName, String(describing: SettingsLiteral.self))
        XCTAssertEqual(SettingsNodes.settingsLiteralOutputPort, SettingsLiteral.outputPort)
        XCTAssertEqual(SettingsLiteral.descriptor.outputPorts, [SettingsNodes.settingsLiteralOutputPort])
        XCTAssertEqual(SettingsNodes.configFilterTypeName, String(describing: ConfigFilter.self))
        XCTAssertEqual(SettingsNodes.configFilterPrefixProperty, ConfigFilter.prefixProperty)
        XCTAssertEqual(SettingsNodes.configFilterInputPort, ConfigFilter.inputPort)
        XCTAssertEqual(SettingsNodes.configFilterOutputPort, ConfigFilter.outputPort)
        XCTAssertEqual(SettingsNodes.configMergerTypeName, String(describing: ConfigMerger.self))
        XCTAssertEqual(SettingsNodes.configMergerBasePort, ConfigMerger.basePort)
        XCTAssertEqual(SettingsNodes.configMergerOverridePort, ConfigMerger.overridePort)
        XCTAssertEqual(SettingsNodes.configMergerOutputPort, ConfigMerger.outputPort)
    }

    /// The trees the builders make are the trees the formula parser makes for the same
    /// text, so a demand built in code and one written in a formula name one node.
    func test_theBuiltTreesRenderAsTheFormulaWouldWriteThem() throws {
        XCTAssertEqual(GraphSpecNode.staticFile(at: "input:/a.c").asString(omitOutputPort: false),
                       "StaticFile(path: 'input:/a.c').output")
        XCTAssertEqual(GraphSpecNode.folderManifest(at: "input:/src").asString(omitOutputPort: false),
                       "Folder(path: 'input:/src').manifest")
        let settings = GraphSpecNode.literals(
            ["moduleName": "App"],
            over: .configFilter(prefix: "swift.compiler", input: [
                "config": .configMerger(base: ["machine": .staticFile(at: "input:/semel.machine.config")],
                                        override: ["project": .staticFile(at: "input:/semel.config")]),
            ]))
        let written = "ConfigMerger(base: ['settings': ConfigFilter(prefix: 'swift.compiler', "
                    + "input: ['config': ConfigMerger(base: ['machine': StaticFile(path: 'input:/semel.machine.config').output], "
                    + "override: ['project': StaticFile(path: 'input:/semel.config').output]).output]).output], "
                    + "override: ['literals': SettingsLiteral(moduleName: 'App').output]).output"
        XCTAssertEqual(settings.asString(omitOutputPort: false), try GraphSpecNode.parse(written).asString(omitOutputPort: false))
        XCTAssertEqual(try settings.identity(), try GraphSpecNode.parse(written).identity())
    }

    /// No literals, no merger: the settings pass through as they are, rather than through a
    /// node that lays nothing over them.
    func test_noLiteralsIsTheSettingsThemselves() throws {
        let selected = GraphSpecNode.configFilter(prefix: "swift.compiler", input: ["config": .staticFile(at: "input:/semel.config")])

        XCTAssertEqual(try GraphSpecNode.literals([:], over: selected).identity(), try selected.identity())
    }
}
