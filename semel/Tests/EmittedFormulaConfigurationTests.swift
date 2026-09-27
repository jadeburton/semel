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
//  the discovery plugin's spec, run them through the real parser and the real graph
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
    /// minimum that happens to satisfy the required keys.
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
        ToolRunnerRegistry.instance = ToolRunnerRegistry()
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
            .appendingPathComponent("semel-cli-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - Building the graph the way the engine does

    /// Runs the converter over `rootManifest`, returning the formula text and the reader
    /// specs it asked for — which is both of the things the engine goes on to build.
    private func convert() throws -> (formula: String, readerSpecs: [String]) {
        let folderManifest = FolderManifest(baseFolderPath: packageFolder, entries: [])
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind))
        // Every compilable target's folder, holding one Swift file: the converter asks for
        // these to tell C targets from Swift ones (B-54), and a manifest is what says so.
        var targetFolders: [String: NodeValue] = [:]
        for (folder, source) in ["input:/repo/app/Sources/App": "App.swift",
                                 "input:/repo/app/Sources/Lib": "Lib.swift",
                                 "input:/repo/Helper/Sources/Helper": "Helper.swift"] {
            let manifest = FolderManifest(baseFolderPath: folder,
                                          entries: [FolderManifestEntry(name: source, isFolder: false, isPinned: true)])
            targetFolders[folder] = .value(try manifest.toJSON().intern())
        }
        let output = try converter.process(input: ProcessInput(inputValues: [
            SwiftFormulaConverter.packageFolder: ["folder": .value(try folderManifest.toJSON().intern())],
            SwiftFormulaConverter.packageJSON:   ["json":   .value(try rootManifest.intern())],
            SwiftFormulaConverter.externalPackageJSONs: [
                "input:/repo/Helper": .value(try externalManifest.intern()),
            ],
            SwiftFormulaConverter.targetFolders: targetFolders,
        ]))

        let formula = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput])
            .expectValue().resolveAsString()
        let specs = try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.externalPackageJSONs])
        return (formula, specs.keys.sorted().compactMap { specs[$0]?.asString(omitOutputPort: false) })
    }

    /// Creates every node one spec string names, exactly as `applySpecs`
    /// does when the engine acts on it.
    private func buildGraph(fromSpec spec: String) throws {
        _ = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()
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

        try processEveryNode(ofKind: ConfigMerger.kind)
        try processEveryNode(ofKind: ConfigFilter.kind)
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
        let (formula, readerSpecs) = try convert()
        try buildGraph(fromFormula: formula)
        for spec in readerSpecs {
            try buildGraph(fromSpec: spec)
        }
        try supplyConfigFile()

        var checked: [String] = []

        for nodeRecord in try database.node.select(kind: SwiftCompiler.kind) {
            let settings = try settingsReaching(nodeRecord, port: SwiftCompiler.configuration)
            XCTAssertNoThrow(try SwiftCompilerConfiguration(properties: settings),
                             "compiler for \(settings["moduleName"] ?? "?")")
            checked.append("compiler:\(settings["moduleName"] ?? "?")")
        }

        for nodeRecord in try database.node.select(kind: SwiftLinker.kind) {
            let settings = try settingsReaching(nodeRecord, port: SwiftLinker.configuration)
            XCTAssertNoThrow(try SwiftLinkerConfiguration(properties: settings),
                             "linker for \(settings["outputName"] ?? "?")")
            checked.append("linker:\(settings["outputName"] ?? "?")")
        }

        for nodeRecord in try database.node.select(kind: SwiftPackageReader.kind) {
            let settings = try settingsReaching(nodeRecord, port: SwiftPackageReader.configuration)
            XCTAssertNoThrow(try SwiftPackageReaderConfiguration(properties: settings),
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
    /// would be building against defaults it never had — config namespaces have none.
    func test_withNoConfigFileEveryNodeFailsNamingTheKeyToWrite() throws {
        let (formula, readerSpecs) = try convert()
        try buildGraph(fromFormula: formula)
        for spec in readerSpecs {
            try buildGraph(fromSpec: spec)
        }

        // The selectors and Configuration nodes still run; what they have to work with is a
        // config file nobody ever pushed.
        try processEveryNode(ofKind: ConfigMerger.kind)
        try processEveryNode(ofKind: ConfigFilter.kind)
        try processEveryNode(ofKind: Configuration.kind)

        for nodeRecord in try database.node.select(kind: SwiftPackageReader.kind) {
            let settings = try settingsReaching(nodeRecord, port: SwiftPackageReader.configuration)
            XCTAssertThrowsError(try SwiftPackageReaderConfiguration(properties: settings)) { error in
                let message = String(describing: error)
                XCTAssertTrue(message.contains("swift.packageReader.toolDescriptor.name"), "got \(message)")
            }
        }
    }

    // MARK: - Where the settings came from

    /// The values are on a wire and not in the identity. This is what makes editing a
    /// setting a cache hit rather than a new node: were a value part of a node's identity,
    /// every node that reads it would become a different node the moment it changes. So
    /// the identity of each node that reads settings is the identity of the spec the
    /// converter emitted for it — a function of the tree alone — before and after the
    /// config file's content arrives.
    func test_noSettingValueEntersANodesIdentity() throws {
        let (formula, readerSpecs) = try convert()
        try buildGraph(fromFormula: formula)
        for spec in readerSpecs {
            try buildGraph(fromSpec: spec)
        }
        let identitiesBefore = try [SwiftCompiler.kind, SwiftLinker.kind, SwiftPackageReader.kind]
            .flatMap { try database.node.select(kind: $0) }
            .map { try XCTUnwrap($0.identity) }
        XCTAssertFalse(identitiesBefore.isEmpty)

        try supplyConfigFile()

        for spec in readerSpecs {
            XCTAssertEqual(try database.node.select(identity: try GraphSpecNode.parse(spec).identity()).count, 1,
                           "the reader's node is the one its spec names, whatever the file says")
        }
        let identitiesAfter = try [SwiftCompiler.kind, SwiftLinker.kind, SwiftPackageReader.kind]
            .flatMap { try database.node.select(kind: $0) }
            .map { try XCTUnwrap($0.identity) }
        XCTAssertEqual(identitiesAfter, identitiesBefore)
    }
}
