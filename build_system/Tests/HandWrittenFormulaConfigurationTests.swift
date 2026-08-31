//
//  HandWrittenFormulaConfigurationTests.swift
//  SemelCLITests
//
//  A `.fmla` that wires its own `ConfigSubset` — the only route a Clang project has to
//  configuration.
//
//  A Swift package gets its selectors written for it by `SwiftFormulaConverter`, and
//  `EmittedFormulaConfigurationTests` covers that. A C or C++ project has no converter: the
//  author writes the selector by hand, names the prefix themselves, and can get it wrong in
//  ways the converter cannot. Nothing exercised that path until the example projects were
//  built by hand, and doing so found four defects — which is the argument for this file
//  rather than against it.
//
//  The formula here is the shape those projects actually use: one config file, a `config`
//  function taking the prefix as a parameter, and three tools each selecting their own.
//

@testable import SemelClang
@testable import SemelCore
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class HandWrittenFormulaConfigurationTests: XCTestCase {

    private var database: DatabaseLayer!

    private let projectFolder = "input:/proj"

    /// Every namespace the formula below selects, plus one that nothing selects, so a test
    /// can tell "filtered out" from "absent".
    private let configFile = """
        // What this project is built with.
        clang.preprocessor.toolDescriptor.name=clang
        clang.preprocessor.toolDescriptor.version=test-clang
        clang.preprocessor.toolDescriptor.platform=macOS
        clang.preprocessor.toolDescriptor.architecture=arm64
        clang.preprocessor.sdkPath=/test/MacOSX.sdk
        clang.preprocessor.target=arm64-apple-macos14.0
        clang.preprocessor.std=c++17

        clang.compiler.toolDescriptor.name=clang
        clang.compiler.toolDescriptor.version=test-clang
        clang.compiler.toolDescriptor.platform=macOS
        clang.compiler.toolDescriptor.architecture=arm64
        clang.compiler.target=arm64-apple-macos14.0
        clang.compiler.std=c++17

        clang.linker.toolDescriptor.name=clang
        clang.linker.toolDescriptor.version=test-clang
        clang.linker.toolDescriptor.platform=macOS
        clang.linker.toolDescriptor.architecture=arm64
        clang.linker.sdkPath=/test/MacOSX.sdk
        clang.linker.target=arm64-apple-macos14.0
        clang.linker.std=c++17

        swift.compiler.sdkVersion=99.9
        """

    /// The shape the example projects use, including `config(prefix)` — a func parameter used
    /// as a node property, which is how every selector in a real formula is built.
    private let formula = """
        func rawConfig() = StaticFile(path: <clang.cfg>)

        func config(prefix) = ConfigSubset(prefix: prefix, input: [rawConfig()])

        func preprocessor(path) = ClangPreprocessorTool(
          configuration: [config(prefix: 'clang.preprocessor')],
          input: [path: StaticFile(path: path)]
        )

        func make(dynamicLibrary) = ClangLinkerTool(
          configuration: [Configuration(inherit: [config(prefix: 'clang.linker')], dynamicLibrary: dynamicLibrary)],
          objectFiles: ["main.c.o": ClangCompilerTool(
            configuration: [config(prefix: 'clang.compiler')],
            input: ["main.c.p": preprocessor(path: 'main.c')])]
        )

        product "app" = make(dynamicLibrary: 'false')
        product "app.dylib" = make(dynamicLibrary: 'true')
        """

    override func setUpWithError() throws {
        try super.setUpWithError()

        DataObjectStore.shared = DataObjectStore(storeRoot: makeTemporaryStoreRoot())
        ToolRunnerRegistry.instance = ToolRunnerRegistry()
        BuildEngine.shared = nil

        database = try DatabaseLayer()
        try BuildEngine.registerTypes()
        try SemelClang.register()
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

    // MARK: - Building the graph the way ProjectBuilder does

    private func buildGraph(configText: String? = nil) throws {
        let products = try FormulaFile.parse(formula,
                                             basePath: Path(projectFolder),
                                             wildcardExpander: { _ in [] })
        XCTAssertFalse(products.isEmpty, "the formula produced no products")
        for name in products.keys.sorted() {
            _ = try products[name]!.findOrCreateMatchingNode()
        }

        guard let configText else {
            return
        }

        var found = 0
        for nodeRecord in try database.node.select(kind: StaticFile.kind)
        where nodeRecord.properties["path"]?.hasSuffix("clang.cfg") == true {
            found += 1
            try nodeRecord.writeToOutputPort(StaticFile.outputPort, value: .value(try configText.intern()))
        }
        XCTAssertGreaterThan(found, 0, "nothing in the graph reads the config file")

        try processEveryNode(ofKind: ConfigSubset.kind)
        try processEveryNode(ofKind: Configuration.kind)
    }

    /// Drives one kind directly. The tools themselves must not run — there is no real source
    /// file — so this stops at the two node types between the file and a tool.
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

    /// The merged text arriving on one node's `configuration` port — exactly what that node's
    /// `init(properties:)` is handed at process time.
    private func settingsReaching(kind: UInt) throws -> [String: String] {
        let nodes = try database.node.select(kind: kind)
        let nodeRecord = try XCTUnwrap(nodes.first, "no node of kind \(kind) in the graph")

        let wires = try nodeRecord.readFromInputPort("configuration")
        XCTAssertFalse(wires.isEmpty, "nothing is wired to the configuration port of kind \(kind)")

        var merged: [String: String] = [:]
        for wireKey in wires.keys.sorted() {
            let text = try wires[wireKey]!.expectValue().resolveAsString()
            merged = merged.mergedWith([String: String](plainText: text))
        }
        return merged
    }

    // MARK: - The formula parses and composes

    /// A func parameter used as a node property. Every selector in a real formula is built
    /// this way, and nothing else in the suite parses that construction.
    func test_aPrefixPassedAsAFuncParameterReachesTheNodesProperties() throws {
        try buildGraph()

        let prefixes = try database.node.select(kind: ConfigSubset.kind)
            .compactMap { $0.properties[ConfigSubset.prefixProperty] }
            .sorted()

        XCTAssertEqual(prefixes, ["clang.compiler", "clang.linker", "clang.preprocessor"])
    }

    /// Two products sharing one config file share its selectors too: the shape names the same
    /// file and the same prefix, so the graph holds one node per prefix rather than one per
    /// product. That sharing is what makes a config edit cheap.
    func test_twoProductsShareOneSelectorPerPrefix() throws {
        try buildGraph()

        XCTAssertEqual(try database.node.select(kind: ConfigSubset.kind).count, 3)
    }

    // MARK: - Each tool gets its own settings, and only its own

    func test_theCompilerReceivesItsOwnNamespaceStripped() throws {
        try buildGraph(configText: configFile)

        let settings = try settingsReaching(kind: ClangCompilerTool.kind)

        XCTAssertEqual(settings["target"], "arm64-apple-macos14.0")
        XCTAssertEqual(settings["std"], "c++17")
        XCTAssertEqual(settings["toolDescriptor.name"], "clang")
    }

    /// The preprocessor reads `sdkPath`; the compiler does not. A key one tool needs must not
    /// arrive at another, because a node's inputs are part of its cache key — an ignored
    /// setting would still rebuild it.
    func test_aKeyOneToolNeedsDoesNotReachAnother() throws {
        try buildGraph(configText: configFile)

        XCTAssertEqual(try settingsReaching(kind: ClangPreprocessorTool.kind)["sdkPath"], "/test/MacOSX.sdk")
        XCTAssertNil(try settingsReaching(kind: ClangCompilerTool.kind)["sdkPath"],
                     "the compiler does not read sdkPath and must not be given it")
    }

    /// Another toolchain's settings in the same file reach nothing here. One master config can
    /// hold every node's settings precisely because a selector takes only its own prefix.
    func test_anotherToolchainsSettingsReachNothing() throws {
        try buildGraph(configText: configFile)

        for kind in [ClangCompilerTool.kind, ClangLinkerTool.kind, ClangPreprocessorTool.kind] {
            let settings = try settingsReaching(kind: kind)
            XCTAssertNil(settings["sdkVersion"], "swift.compiler.sdkVersion leaked into kind \(kind)")
            XCTAssertFalse(settings.keys.contains { $0.hasPrefix("swift.") })
        }
    }

    /// The linker's settings come through a `Configuration` that also carries a literal from
    /// the formula. Both have to arrive: the file says what environment to build in, the
    /// literal says what the product is.
    func test_aLiteralInTheFormulaAndTheFileBothReachTheLinker() throws {
        try buildGraph(configText: configFile)

        let settings = try settingsReaching(kind: ClangLinkerTool.kind)

        XCTAssertEqual(settings["target"], "arm64-apple-macos14.0", "from the file")
        XCTAssertNotNil(settings["dynamicLibrary"], "from the formula")
    }

    // MARK: - Completeness

    /// The assertion no unit test can make: every tool the formula names can construct its
    /// configuration from what it was actually wired to. A formula can be perfect text and
    /// still describe a build that cannot start — that is exactly how two defects reached
    /// the end of this branch's review.
    func test_everyToolInTheGraphCanConstructItsConfiguration() throws {
        try buildGraph(configText: configFile)

        var checked = 0
        for kind in [ClangCompilerTool.kind, ClangLinkerTool.kind, ClangPreprocessorTool.kind] {
            let properties = try settingsReaching(kind: kind)
            switch kind {
            case ClangCompilerTool.kind:
                XCTAssertNoThrow(try ClangCompilerToolConfiguration(properties: properties))
            case ClangLinkerTool.kind:
                XCTAssertNoThrow(try ClangLinkerToolConfiguration(properties: properties))
            default:
                XCTAssertNoThrow(try ClangPreprocessorToolConfiguration(properties: properties))
            }
            checked += 1
        }
        XCTAssertEqual(checked, 3, "every Clang tool kind must have been reached")
    }

    /// The failure a project meets when a prefix is misspelt, or the file is absent: the tool
    /// names the setting it wanted and where to write it, rather than failing somewhere deeper
    /// with something about a wire.
    func test_aMissingConfigFileFailsByNamingWhatToWrite() throws {
        try buildGraph(configText: "")

        XCTAssertThrowsError(
            try ClangCompilerToolConfiguration(properties: try settingsReaching(kind: ClangCompilerTool.kind))
        ) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("clang.compiler.target"), "got \(message)")
            XCTAssertTrue(message.contains("semel.config"), "should say where to write it: \(message)")
        }
    }

    /// A misspelt prefix selects nothing, so the file's keys go unclaimed. This is the report
    /// that tells a user their setting reached no one — the case the per-tool accepted-key
    /// check could never see.
    func test_aPrefixNoSelectorClaimsIsReported() throws {
        try buildGraph(configText: configFile)

        let engine = try BuildEngine(database: database, startProcessingLoop: false)
        let fileNode = try XCTUnwrap(try database.node.select(kind: StaticFile.kind)
            .first { $0.properties["path"]?.hasSuffix("clang.cfg") == true })

        let unclaimed = try engine.unclaimedConfigKeys(inFileNodeID: fileNode.requireID())

        XCTAssertEqual(unclaimed, ["swift.compiler.sdkVersion"],
                       "only the key no selector's prefix covers")
    }
}
