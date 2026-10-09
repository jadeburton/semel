//
//  OneWirePortTests.swift
//  SemelCoreTests
//
//  B-141. A port declared to hold one wire holds one, for every node. A formula wiring two
//  configurations to one compiler is refused when the graph is built, by the applier, with
//  an error naming the node's type, the port and the wires; the builder that applied the
//  formula carries it, and `errors` names it there. A port declared `.many` is unaffected.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class OneWirePortTests: SemelCoreTestCase {

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

    /// A tool reading two sets of settings on its `configuration`, which takes one.
    private let twoConfigurations = """
        SampleTool(configuration: ['machine': SettingsLiteral(a: '1').output, \
        'project': SettingsLiteral(a: '2').output]).output
        """

    // MARK: - When the graph is built

    /// Refused before the node is made: the error is the applier's, typed, naming the
    /// tool's type, its port and both wires, and the graph holds no tool afterwards.
    func test_aSpecWiringTwoWiresToAToolsOneWirePortIsRefusedNamingTheNodeAndThePort() throws {
        XCTAssertThrowsError(try GraphSpecNode.parse(twoConfigurations).findOrCreateMatchingNode()) { error in
            guard case GraphSpecApplierError.severalWiresOnOneWirePort(let typeName, let portName, let wires) = error else {
                return XCTFail("expected severalWiresOnOneWirePort, got \(error)")
            }
            XCTAssertEqual(typeName, "SampleTool")
            XCTAssertEqual(portName, SampleTool.configuration)
            XCTAssertEqual(wires, ["machine", "project"])
        }
        XCTAssertTrue(try database.node.selectAll().allSatisfy { $0.kind != SampleTool.kind })
    }

    /// A port declared `.many` takes as many wires as the formula names.
    func test_aManyWirePortTakesSeveralWires() throws {
        let spec = try GraphSpecNode.parse("""
            TreeMerger(input: ['a': SettingsLiteral(a: '1').output, 'b': SettingsLiteral(a: '2').output]).output
            """)
        let (merger, _) = try spec.findOrCreateMatchingNode()

        let wires = try database.wire.select(goingToNodeID: try merger.requireID(),
                                             toSymbolID:    TreeMerger.inputPort.asSymbolID())
        XCTAssertEqual(wires.count, 2)
    }

    // MARK: - Where the error is read

    /// A formula's builder applies what it reads, so a refused product is an error on the
    /// builder, and `errors` names it there with the tool's type, the port and the wires —
    /// the node the user has to edit is the formula's.
    func test_aFormulaWiringTwoConfigurationsIsReportedOnItsBuilderNamingThePortAndTheWires() throws {
        let formula = "product 'app' = \(twoConfigurations)"
        try StaticFile.push(Array(formula.utf8), mode: FileMetadata.defaultMode, at: Path("repo/semel.fmla"))
        let builderSpec = GraphSpecNode(ProjectBuilder.self,
                                        inputs: [ProjectBuilder.projectFileInputPort:
                                                    ["input:/repo/semel.fmla": .staticFile(at: "input:/repo/semel.fmla")]])
        let (builder, _) = try builderSpec.findOrCreateMatchingNode()

        XCTAssertThrowsError(try builder.makeNode().processWithPreCheck())

        let entries = ErrorReport.entries(forErrorPorts: try ErrorReport.portsToReport(database: database),
                                          database: database,
                                          select: { _, messages in messages }).map(\.entry)
        let entry = try XCTUnwrap(entries.first { $0.label.hasPrefix("ProjectBuilder #\(try builder.requireID())") },
                                  "expected the builder to be named, got \(entries.map(\.label))")
        XCTAssertEqual(entry.items.map(\.message),
                       ["SampleTool's input 'configuration' takes one wire, and 2 are wired to it: 'machine', "
                        + "'project'. Wire it once; settings from two places meet in a ConfigMerger, whose base "
                        + "and override say which wins"])
    }
}
