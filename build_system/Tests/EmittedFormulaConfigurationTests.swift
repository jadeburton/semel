//
//  EmittedFormulaConfigurationTests.swift
//  SemelCLITests
//
//  Whether the formula SwiftFormulaConverter emits is *complete* — not merely whether it
//  parses.
//
//  A formula can be perfect text and still describe a build that cannot start: a tool wired
//  to a `Configuration()` with nothing in it parses, builds a graph, and then throws the
//  moment the node reads its settings. Two such holes shipped through six task reviews on
//  this branch, both invisible to every test that existed, because SemelSwift deliberately
//  does not depend on the engine and so cannot compose what it emits. This target can see
//  both, which is the whole reason it is where this lives.
//
//  So the assertion here is the one no unit test can make: take the converter's output and
//  the discovery plugin's shape, run them through the real parser and the real graph
//  applier, supply a config file, and require that *every* node the graph ends up holding
//  can construct its configuration. Nothing is listed by hand -- a node type added to the
//  converter tomorrow is covered the day it is added.
//

@testable import SemelCore
@testable import SemelSwift
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class EmittedFormulaConfigurationTests: XCTestCase {

    private var database: DatabaseLayer!

    /// The config file this build is given. Deliberately the shape a real one has —
    /// comments, blank lines, every namespace the Swift tools claim — rather than the
    /// minimum that happens to satisfy today's required keys.
    private let configFile = """
        // Settings for the tools this package's formula names.
        swift.compiler.toolDescriptor.name=swiftc
        swift.compiler.toolDescriptor.version=test-swiftc
        swift.compiler.toolDescriptor.platform=macOS
        swift.compiler.toolDescriptor.architecture=arm64

        swift.linker.toolDescriptor.name=swiftc
        swift.linker.toolDescriptor.version=test-swiftc
        swift.linker.toolDescriptor.platform=macOS
        swift.linker.toolDescriptor.architecture=arm64

        swift.packageReader.toolDescriptor.name=swift
        swift.packageReader.toolDescriptor.version=test-swift
        swift.packageReader.toolDescriptor.platform=macOS
        swift.packageReader.toolDescriptor.architecture=arm64
        """

    /// A package with an executable, a library it depends on, and a vendored external
    /// dependency — so the graph holds a compiler, a linker, and the reader the converter
    /// creates for someone else's checkout.
    private let rootManifest = """
        {
          "name": "app",
          "dependencies": [
            {"fileSystem": [{"identity": "helper", "path": "../Helper"}]}
          ],
          "products": [
            {"name": "app", "targets": ["App"], "type": {"executable": []}}
          ],
          "targets": [
            {"name": "App", "type": "executable", "path": "Sources/App",
             "dependencies": [{"byName": ["Lib", null]}, {"product": ["Helper", "Helper", null, null]}]},
            {"name": "Lib", "type": "regular", "path": "Sources/Lib", "dependencies": []}
          ]
        }
        """

    private let externalManifest = """
        {
          "name": "Helper",
          "dependencies": [],
          "products": [
            {"name": "Helper", "targets": ["Helper"], "type": {"library": ["automatic"]}}
          ],
          "targets": [
            {"name": "Helper", "type": "regular", "path": "Sources/Helper", "dependencies": []}
          ]
        }
        """

    private let packageFolder = "input:/repo/app"

    override func setUpWithError() throws {
        try super.setUpWithError()

        DataObjectStore.shared        = DataObjectStore(storeRoot: makeTemporaryStoreRoot())
        ToolExecutorRegistry.instance = ToolExecutorRegistry()
        BuildEngine.shared            = nil

        // Both halves of the rulebook. The parser resolves a type name and its default
        // output port through TypeRegistry, so a graph built without SemelSwift registered
        // would fail for a reason that has nothing to do with configuration.
        database = try DatabaseLayer()
        try BuildEngine.registerTypes()
        try SemelSwift.register()
    }

    override func tearDown() {
        database = nil
        super.tearDown()
    }

    private func makeTemporaryStoreRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("build_system-cli-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - Building the graph the way the engine does

    /// Runs the converter over `rootManifest`, returning the formula text and the reader
    /// expectations it asked for — which is both of the things the engine goes on to build.
    private func convert() throws -> (formula: String, readerExpectations: [String]) {
        let folderManifest = FolderManifest(baseFolderPath: packageFolder, entries: [])
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind))
        let output = try converter.process(input: ProcessInput(inputValues: [
            SwiftFormulaConverter.packageFolder: ["folder": .value(try folderManifest.toJSON().intern())],
            SwiftFormulaConverter.packageJSON:   ["json":   .value(try rootManifest.intern())],
            SwiftFormulaConverter.externalPackageJSONs: [
                "input:/repo/Helper": .value(try externalManifest.intern()),
            ],
        ]))

        let formula = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput])
            .expectValue().resolveAsString()
        let expectations = try XCTUnwrap(output.inputWireExpectations[SwiftFormulaConverter.externalPackageJSONs])
        return (formula, expectations.keys.sorted().compactMap { expectations[$0] })
    }

    /// Creates every node one expectation string names, exactly as `applyExpectationConfiguration`
    /// does when the engine acts on it.
    private func buildGraph(fromExpectation expectation: String) throws {
        _ = try GraphShapeNode.parse(expectation).findOrCreateMatchingNode()
    }

    /// Creates every node the formula's products name, exactly as ProjectBuilder does.
    private func buildGraph(fromFormula formula: String) throws {
        let products = try FormulaFile.parse(formula,
                                             basePath: Path(packageFolder),
                                             wildcardExpander: { _ in [] })
        XCTAssertFalse(products.isEmpty, "the converter emitted no products:\n\(formula)")
        for name in products.keys.sorted() {
            _ = try products[name]!.findOrCreateMatchingNode()
        }
    }

    /// Pushes `configFile` onto every `semel.config` StaticFile in the graph, then drives the
    /// two node types between it and a tool so their outputs are on the wire.
    ///
    /// Driven directly rather than through the engine's loop because the tools themselves
    /// must not run: their source folders do not exist, so they would fail for reasons that
    /// have nothing to do with what is being asserted.
    private func supplyConfigFile() throws {
        var configFilesFound = 0
        for nodeRecord in try database.node.select(kind: StaticFile.kind) {
            guard nodeRecord.properties["path"]?.hasSuffix(SwiftFormulaConverter.configFileName) == true else { continue }
            configFilesFound += 1
            try nodeRecord.writeToOutputPort(StaticFile.outputPort, value: .value(try configFile.intern()))
        }
        XCTAssertGreaterThan(configFilesFound, 0, "nothing in the graph reads a config file")

        try processEveryNode(ofKind: ConfigSubset.kind)
        try processEveryNode(ofKind: Configuration.kind)
    }

    private func processEveryNode(ofKind kind: UInt) throws {
        for nodeRecord in try database.node.select(kind: kind) {
            let node = try nodeRecord.makeNode()
            var inputValues: [String: [String: NodeValue]] = [:]
            for port in node.descriptor.inputPorts {
                inputValues[port.name] = try nodeRecord.readFromInputPort(port.name)
            }
            try node.writeToOutputs(output: try node.process(input: ProcessInput(inputValues: inputValues)))
        }
    }

    /// The merged `key=value` text arriving on one node's `configuration` port — the exact
    /// value the node's own `init(properties:)` is handed at process time.
    private func settingsReaching(_ nodeRecord: NodeRecord, port: String) throws -> [String: String] {
        let wires = try nodeRecord.readFromInputPort(port)
        XCTAssertFalse(wires.isEmpty, "nothing is wired to \(nodeRecord.kind)'s \(port) port")

        var merged: [String: String] = [:]
        for wireKey in wires.keys.sorted() {
            let text = try wires[wireKey]!.expectValue().resolveAsString()
            merged = merged.mergedWith([String: String](plainText: text))
        }
        return merged
    }

    // MARK: - The assertion

    /// Every node the converter and the plugin put in the graph must be able to construct
    /// its configuration from the file it was wired to. This is the guard that catches a
    /// node wired to an empty `Configuration()`, or to a config file nothing wrote.
    func test_everyEmittedNodeResolvesItsConfiguration() throws {
        let (formula, readerExpectations) = try convert()
        try buildGraph(fromFormula: formula)
        for expectation in readerExpectations {
            try buildGraph(fromExpectation: expectation)
        }
        try supplyConfigFile()

        var checked: [String] = []

        for nodeRecord in try database.node.select(kind: SwiftCompilerTool.kind) {
            let settings = try settingsReaching(nodeRecord, port: SwiftCompilerTool.configuration)
            XCTAssertNoThrow(try SwiftCompilerToolConfiguration(properties: settings),
                             "compiler for \(settings["moduleName"] ?? "?")")
            checked.append("compiler:\(settings["moduleName"] ?? "?")")
        }

        for nodeRecord in try database.node.select(kind: SwiftLinkerTool.kind) {
            let settings = try settingsReaching(nodeRecord, port: SwiftLinkerTool.configuration)
            XCTAssertNoThrow(try SwiftLinkerToolConfiguration(properties: settings),
                             "linker for \(settings["outputName"] ?? "?")")
            checked.append("linker:\(settings["outputName"] ?? "?")")
        }

        for nodeRecord in try database.node.select(kind: SwiftPackageReaderTool.kind) {
            let settings = try settingsReaching(nodeRecord, port: SwiftPackageReaderTool.configuration)
            XCTAssertNoThrow(try SwiftPackageReaderToolConfiguration(properties: settings),
                             "package reader")
            checked.append("packageReader")
        }

        // The list itself, so a converter that silently stops emitting a node type fails
        // here rather than passing an assertion it never ran.
        XCTAssertEqual(checked.sorted(),
                       ["compiler:App", "compiler:Helper", "compiler:Lib",
                        "linker:app", "packageReader"])
    }

    /// The same graph with no config file pushed. Every one of those nodes must fail, and
    /// fail by naming a key to write -- because that error is the entire user interface for
    /// "this build cannot start", and a node that quietly accepted an empty configuration
    /// would be building against defaults that no longer exist.
    func test_withNoConfigFileEveryNodeFailsNamingTheKeyToWrite() throws {
        let (formula, readerExpectations) = try convert()
        try buildGraph(fromFormula: formula)
        for expectation in readerExpectations {
            try buildGraph(fromExpectation: expectation)
        }

        // The selectors and Configuration nodes still run; what they have to work with is a
        // config file nobody ever pushed.
        try processEveryNode(ofKind: ConfigSubset.kind)
        try processEveryNode(ofKind: Configuration.kind)

        for nodeRecord in try database.node.select(kind: SwiftPackageReaderTool.kind) {
            let settings = try settingsReaching(nodeRecord, port: SwiftPackageReaderTool.configuration)
            XCTAssertThrowsError(try SwiftPackageReaderToolConfiguration(properties: settings)) { error in
                let message = String(describing: error)
                XCTAssertTrue(message.contains("swift.packageReader.toolDescriptor.name"), "got \(message)")
            }
        }
    }

    // MARK: - Where the settings came from

    /// The values are on a wire and not in the shape. This is what makes editing a setting
    /// a cache hit rather than a new node: put a value in a searchKey and every node that
    /// reads it becomes a different node the moment it changes.
    func test_noSettingValueAppearsInANodesSearchKey() throws {
        let (formula, readerExpectations) = try convert()
        try buildGraph(fromFormula: formula)
        for expectation in readerExpectations {
            try buildGraph(fromExpectation: expectation)
        }
        try supplyConfigFile()

        for kind in [SwiftCompilerTool.kind, SwiftLinkerTool.kind, SwiftPackageReaderTool.kind] {
            for nodeRecord in try database.node.select(kind: kind) {
                let searchKey = nodeRecord.searchKey ?? ""
                XCTAssertFalse(searchKey.contains("test-swiftc"), "got:\n\(searchKey)")
                XCTAssertFalse(searchKey.contains("test-swift"), "got:\n\(searchKey)")
            }
        }
    }
}
