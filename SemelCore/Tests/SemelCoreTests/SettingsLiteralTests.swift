//
//  SettingsLiteralTests.swift
//  SemelCoreTests
//
//  B-120. Settings written into a formula are a source: the properties are the value, and
//  nothing is laid over or under them here. Where they meet a config file's settings is a
//  `ConfigMerger`, and one wire per settings port is what keeps it the only place.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class SettingsLiteralTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private var database: DatabaseLayer { engine.database }

    private func text(on node: NodeRecord, port: String) throws -> String {
        try node.readFromOutputPort(port).expectValue().resolveAsString()
    }

    // MARK: - A source

    /// The value is there as soon as the node is: its properties as configuration text,
    /// sorted, with nothing to wait for and nothing to process.
    func test_publishesItsPropertiesWhenItIsCreated() throws {
        let (node, _) = try GraphSpecNode.settingsLiteral(["outputName": "App", "linkage": "executable"])
            .findOrCreateMatchingNode()

        XCTAssertEqual(try text(on: node, port: SettingsLiteral.outputPort), "linkage=executable\noutputName=App")
        XCTAssertFalse(try database.node.select(nodeID: try node.requireID()).scheduled,
                       "a source is never scheduled: there is nothing to hand it")
    }

    func test_declaresNoInputPort() {
        XCTAssertTrue(SettingsLiteral.descriptor.inputPorts.isEmpty)
        XCTAssertFalse(SettingsLiteral.descriptor.hasInputs)
    }

    /// The port it merged through is gone, so a formula still writing it says so at once
    /// rather than building a literal that silently ignores what it was handed.
    func test_aFormulaCannotWireSettingsIntoIt() throws {
        let spec = "SettingsLiteral(moduleName: 'App', base: ['settings': SettingsLiteral(role: 'x').output]).output"

        XCTAssertThrowsError(try GraphSpecNode.parse(spec).findOrCreateMatchingNode())
    }

    /// With no static input port it is not stamped with a project's root, so the same
    /// literals written by two projects are one node.
    func test_isNotStampedWithTheProjectRoot() {
        XCTAssertFalse(ProjectBuilder.isCacheable(.settingsLiteral(["moduleName": "App"])))
    }

    // MARK: - Laid over settings, by a merger

    /// The shape every prelude and converter writes: the selected settings as the base, the
    /// literals as the override, and the literals win.
    func test_aMergerLaysTheLiteralsOverTheSettings() throws {
        let (file, _) = try GraphSpecNode.staticFile(at: "input:/semel.config").findOrCreateMatchingNode()
        let staticFile = try XCTUnwrap(file.nodeAsAny() as? StaticFile)
        _ = try staticFile.replaceContent(try "moduleName=FromTheFile\nsdkVersion=26.5".intern())

        let (merger, _) = try GraphSpecNode.literals(["moduleName": "App"], over: .staticFile(at: "input:/semel.config"))
            .findOrCreateMatchingNode()
        try merger.makeNode().processWithPreCheck()

        XCTAssertEqual(try text(on: merger, port: ConfigMerger.outputPort), "moduleName=App\nsdkVersion=26.5")
    }

    /// Two sets of settings on one of the merger's ports is the merge this node exists to
    /// make explicit, done implicitly: the formula is refused when the graph is built, naming
    /// the merger, its port and both wires, and no merger is made (B-141).
    func test_twoWiresOnAMergersBaseAreRefusedWhenTheGraphIsBuilt() throws {
        let spec = """
            ConfigMerger(base: ['machine': SettingsLiteral(a: '1').output, 'project': SettingsLiteral(a: '2').output], \
            override: ['literals': SettingsLiteral(b: '3').output]).output
            """
        XCTAssertThrowsError(try GraphSpecNode.parse(spec).findOrCreateMatchingNode()) { error in
            guard case GraphSpecApplierError.severalWiresOnOneWirePort(let typeName, let portName, let wires) = error else {
                return XCTFail("expected severalWiresOnOneWirePort, got \(error)")
            }
            XCTAssertEqual(typeName, "ConfigMerger")
            XCTAssertEqual(portName, ConfigMerger.basePort)
            XCTAssertEqual(wires, ["machine", "project"])
            XCTAssertEqual("\(error)", "ConfigMerger's input 'base' takes one wire, and 2 are wired to it: "
                                     + "'machine', 'project'. Wire it once; settings from two places meet in a "
                                     + "ConfigMerger, whose base and override say which wins")
        }
        XCTAssertTrue(try DatabaseLayer.shared.node.selectAll().allSatisfy { $0.kind != ConfigMerger.kind })
    }
}
