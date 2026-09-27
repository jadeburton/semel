//
//  FormulaPreludeTests.swift
//  SemelCoreTests
//
//  B-108. A plugin answers include names with formula text; the engine asks every
//  provider, publishes the one answer on a `FormulaPrelude` node's port, and asks again at
//  every start.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class FormulaPreludeTests: SemelCoreTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = try DatabaseLayer()
    }

    /// A plugin that answers the names it was given, and refuses the ones it was told to.
    private struct TestProvider: FormulaIncludeProvider {
        let pluginName: String
        var preludes: [String: String] = [:]
        var refusals: [String: String] = [:]

        func answer(forIncludeNamed name: String) -> FormulaIncludeAnswer? {
            if let text = preludes[name] {
                return .prelude(namespace: name, text: text)
            }
            return refusals[name].map { .refused(reason: $0) }
        }
    }

    private func preludeNode(named name: String) throws -> NodeRecord {
        try GraphSpecNode.parse("FormulaPrelude(name: '\(name)')").findOrCreateMatchingNode().0
    }

    private func published(_ nodeRecord: NodeRecord) throws -> String {
        try nodeRecord.readFromOutputPort(FormulaPrelude.formulaOutputPort).expectValue().resolveAsString()
    }

    private func publishedError(_ nodeRecord: NodeRecord) throws -> String? {
        let value = try nodeRecord.readFromOutputPort(FormulaPrelude.formulaOutputPort)
        guard case .noValue(.error(let hash)) = value else {
            return nil
        }
        return try hash.resolveAsString()
    }

    // MARK: - Asking the providers

    func test_theOnePluginThatAnswersProvidesThePrelude() {
        FormulaIncludeProviders.register(TestProvider(pluginName: "SemelClang", preludes: ["clang": "func x() = X()"]))
        FormulaIncludeProviders.register(TestProvider(pluginName: "SemelSwift", preludes: ["swift": "func y() = Y()"]))

        XCTAssertEqual(FormulaIncludeProviders.resolve(includeNamed: "clang"),
                       .prelude(namespace: "clang", text: "func x() = X()"))
    }

    /// Why the include failed, in the plugin's words, against the name the user wrote.
    func test_aRefusalIsTheSentenceTheUserReads() {
        FormulaIncludeProviders.register(TestProvider(pluginName: "SemelClang",
                                                      refusals: ["clang/c++26": "no installed clang supports C++26 (found 17.0.0)"]))

        XCTAssertEqual(FormulaIncludeProviders.resolve(includeNamed: "clang/c++26"),
                       .failed(message: "include 'clang/c++26': no installed clang supports C++26 (found 17.0.0)"))
    }

    /// Nobody answered: say what is installed, so the user can see what is missing.
    func test_aNameNobodyAnswersListsTheInstalledPlugins() {
        FormulaIncludeProviders.register(TestProvider(pluginName: "SemelSwift"))
        FormulaIncludeProviders.register(TestProvider(pluginName: "SemelClang"))

        XCTAssertEqual(FormulaIncludeProviders.resolve(includeNamed: "rust"),
                       .failed(message: "include 'rust': no plugin answers this name (installed: SemelClang, SemelSwift)"))
    }

    /// Never first-wins — and a refusal claims the name as a prelude does.
    func test_twoPluginsClaimingOneNameIsAFailureNamingBoth() {
        FormulaIncludeProviders.register(TestProvider(pluginName: "SemelClang", preludes: ["c": "func x() = X()"]))
        FormulaIncludeProviders.register(TestProvider(pluginName: "OtherC", refusals: ["c": "not today"]))

        XCTAssertEqual(FormulaIncludeProviders.resolve(includeNamed: "c"),
                       .failed(message: "include 'c': claimed by both OtherC and SemelClang"))
    }

    // MARK: - The node

    func test_aPreludeNodeIsFilledWhenItIsCreated() throws {
        FormulaIncludeProviders.register(TestProvider(pluginName: "SemelClang", preludes: ["clang": "func x() = X()"]))

        XCTAssertEqual(try published(try preludeNode(named: "clang")), "namespace clang\nfunc x() = X()")
    }

    func test_aNameNobodyAnswersIsAnErrorOnThePort() throws {
        XCTAssertEqual(try publishedError(try preludeNode(named: "clang")),
                       "include 'clang': no plugin answers this name (no plugin provides includes)")
    }

    /// A plugin replaced between two starts: the new text reaches the port, and the builder
    /// that includes it is woken.
    func test_theProvidersAreAskedAgainAtStartAndAChangeWakesTheConsumer() throws {
        FormulaIncludeProviders.register(TestProvider(pluginName: "SemelClang", preludes: ["clang": "func x() = Old()"]))
        let prelude  = try preludeNode(named: "clang")
        let consumer = try NodeRecord.createNode(database: DatabaseLayer.shared, kind: SampleTool.kind,
                                                 properties: [:], identity: nil)
        try Wire.connectWire(database: DatabaseLayer.shared,
                             fromNodeID:   try prelude.requireID(),
                             fromSymbolID: FormulaPrelude.formulaOutputPort.asSymbolID(),
                             toNodeID:     try consumer.requireID(),
                             toSymbolID:   "input".asSymbolID(),
                             name:         "clang".asSymbolID())
        // Settled, so the wake below is the refresh's doing.
        try DatabaseLayer.shared.node.select(nodeID: try consumer.requireID()).setScheduled(false)

        FormulaIncludeProviders.register(TestProvider(pluginName: "SemelClang", preludes: ["clang": "func x() = New()"]))
        try FormulaPrelude.refreshAll(database: DatabaseLayer.shared)

        XCTAssertEqual(try published(prelude), "namespace clang\nfunc x() = New()")
        XCTAssertTrue(try DatabaseLayer.shared.node.select(nodeID: try consumer.requireID()).scheduled)
    }

    // MARK: - Through a builder

    /// The whole path a formula takes: `include 'clang'` wires the prelude node, and once its
    /// text is on the wire the formula's call through the namespace resolves to products.
    func test_aFormulaIncludingAPreludePublishesWhatItsCallsBuild() throws {
        let formula = """
            include 'clang'
            product 'hello' = clang.executable(sources: <src>)
            """
        let preludeSpec = FormulaPrelude.spec(forIncludeNamed: "clang").asString(omitOutputPort: false)
        let text = FormulaPrelude.publishedText(namespace: "clang", text: """
            func executable(sources) = Configuration(sources: sources).output
            """)

        var builderRecord = NodeRecord(parentNodeID: nil, kind: ProjectBuilder.kind, name: nil,
                                       properties: ["outputFolder": "input:/repo"], scheduled: false, identity: nil)
        builderRecord.id = try DatabaseLayer.shared.node.insert(builderRecord)
        try builderRecord.writePendingToAllOutputsOfNode()
        let output = try ProjectBuilder(thisNode: builderRecord).process(input: ProcessInput(inputValues: [
            ProjectBuilder.projectFileInputPort:  ["input:/repo/semel.fmla": .value(try formula.intern())],
            ProjectBuilder.productInputPort:      [:],
            ProjectBuilder.foldersInputPort:      [:],
            ProjectBuilder.graphImportsInputPort: [:],
            ProjectBuilder.includesInputPort:     [preludeSpec: .value(try text.intern())],
        ]))

        XCTAssertEqual(output.inputWireSpecs[ProjectBuilder.includesInputPort], [preludeSpec: preludeSpec])
        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[ProjectBuilder.productInputPort]).keys.sorted(),
                       ["output:/repo/hello"])
    }
}
