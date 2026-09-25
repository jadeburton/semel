//
//  CacheTests.swift
//  semel_tests
//
//  A wrong cache hit is the worst failure a build system has: the output looks fine.
//  These pin down what does and does not participate in the key.
//

@testable import SemelCore
import XCTest
import SemelNodeKit

final class CacheTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeCompilerNode() throws -> SampleTool {
        let spec = try GraphSpecNode.parse("SampleTool()")
        let (node, _) = try spec.findOrCreateMatchingNode()
        return try SampleTool(thisNode: node)
    }

    private func configuration(toolVersion: String = "sample tool version 1",
                               extra: [String: String] = [:]) -> String {
        var properties = [
            "toolDescriptor.name": "sample",
            "toolDescriptor.version": toolVersion,
            "toolDescriptor.platform": "macOS",
            "toolDescriptor.architecture": "arm64",
        ]
        properties.merge(extra) { _, new in new }
        return properties.sorted { $0.key < $1.key }
                         .map { "\($0.key)=\($0.value)" }
                         .joined(separator: "\n")
    }

    private func makeInput(configuration config: String? = nil,
                           sourcePath: String = "src/hello.c.p",
                           contents: String = "int main(){}") throws -> ProcessInput {
        ProcessInput(inputValues: [
            SampleTool.configuration: ["configuration": .value(try (config ?? configuration()).intern())],
            SampleTool.input: [sourcePath: .value(try contents.intern())],
        ])
    }

    /// A result of the shape `SampleTool.process` returns, for the tests that need an
    /// entry in the cache rather than a particular value in it.
    private func builtOutput() throws -> ProcessOutput {
        ProcessOutput(outputValues: [SampleTool.output:   .value(try "OBJECT".intern()),
                                     SampleTool.errorLog: .value(""),
                                     SampleTool.infoLog:  .value("")],
                      inputWireSpecs: [:])
    }

    // MARK: - Machine-derived inputs

    /// Pins the key format. A cache key is a promise that identical inputs mean an
    /// identical build, so an unintended change to how it is composed silently discards
    /// every existing entry — and, on a shared cache, does it for everyone.
    ///
    /// Re-recorded when this test's subject moved from ClangCompiler to SampleTool:
    /// the node type's name is part of the key, so the value had to change even though the
    /// format did not. That cost the original provenance — it no longer proves the
    /// environment hook left keys untouched — but it buys something better going forward,
    /// because SampleTool exists only for these tests and will not be moved again.
    ///
    /// Re-recorded a second time for `implementationVersion` (B-102): the version of the
    /// node type's implementation joined the key, which is one deliberate discard of every
    /// entry in exchange for every later upgrade discarding only what it touched.
    func test_theKeyFormatHasNotDrifted() throws {
        let key = try makeCompilerNode().buildCacheKeyFromAllInputs(input: try makeInput())

        XCTAssertEqual(key, "285a5050ac7e8501af9c3bab064c1cf5432b67646d915ae3477fe816dced6419")
    }

    // MARK: - What the key covers

    func test_identicalInputsProduceTheSameKey() throws {
        let tool = try makeCompilerNode()

        let first  = try tool.buildCacheKeyFromAllInputs(input: try makeInput())
        let second = try tool.buildCacheKeyFromAllInputs(input: try makeInput())

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func test_changingTheSourceContentChangesTheKey() throws {
        let tool = try makeCompilerNode()

        let before = try tool.buildCacheKeyFromAllInputs(input: try makeInput(contents: "int main(){}"))
        let after  = try tool.buildCacheKeyFromAllInputs(input: try makeInput(contents: "int main(){return 1;}"))

        XCTAssertNotEqual(before, after, "edited source must not reuse the cached object")
    }

    func test_changingTheSourcePathChangesTheKey() throws {
        let tool = try makeCompilerNode()

        let before = try tool.buildCacheKeyFromAllInputs(input: try makeInput(sourcePath: "a.p"))
        let after  = try tool.buildCacheKeyFromAllInputs(input: try makeInput(sourcePath: "b.p"))

        XCTAssertNotEqual(before, after, "the wire key names the file being compiled")
    }

    /// The tool descriptor reaches the key through the configuration input port. This is
    /// what makes a compiler change invalidate cached objects — but only to the extent
    /// that the *declared* version is kept in step with the compiler actually installed.
    func test_changingTheDeclaredToolVersionChangesTheKey() throws {
        let tool = try makeCompilerNode()

        let before = try tool.buildCacheKeyFromAllInputs(
            input: try makeInput(configuration: configuration(toolVersion: "sample tool version 1")))
        let after = try tool.buildCacheKeyFromAllInputs(
            input: try makeInput(configuration: configuration(toolVersion: "sample tool version 2")))

        XCTAssertNotEqual(before, after, "a different compiler must produce a different key")
    }

    func test_changingAnyConfigurationPropertyChangesTheKey() throws {
        let tool = try makeCompilerNode()

        let before = try tool.buildCacheKeyFromAllInputs(input: try makeInput())
        let after  = try tool.buildCacheKeyFromAllInputs(
            input: try makeInput(configuration: configuration(extra: ["optimisation": "-O2"])))

        XCTAssertNotEqual(before, after, "configuration is an input, so it belongs in the key")
    }

    func test_differentNodeTypesDoNotShareAKey() throws {
        let compilerShape = try GraphSpecNode.parse("SampleTool()")
        let (compilerNode, _) = try compilerShape.findOrCreateMatchingNode()
        let preprocessorShape = try GraphSpecNode.parse("OtherSampleTool()")
        let (preprocessorNode, _) = try preprocessorShape.findOrCreateMatchingNode()

        let compiler = try SampleTool(thisNode: compilerNode)
        let preprocessor = try OtherSampleTool(thisNode: preprocessorNode)

        let input = try makeInput()
        let compilerKey = try compiler.buildCacheKeyFromAllInputs(input: input)
        let preprocessorKey = try? preprocessor.buildCacheKeyFromAllInputs(input: input)

        XCTAssertNotEqual(compilerKey, preprocessorKey ?? "",
                          "the node type is part of the key")
    }

    // MARK: - Which implementation produced the entry

    /// B-102. The inputs, the properties and the tool descriptors say what was built; none
    /// of them says which code built it. A node type that changes what it emits for equal
    /// inputs declares a new `implementationVersion`, and every key that type produces
    /// becomes a different key — so an entry of the older implementation is a miss rather
    /// than a wrong hit.
    func test_twoImplementationVersionsOfOneNodeTypeDoNotShareAKey() throws {
        let tool  = try makeCompilerNode()
        let input = try makeInput()
        defer { SampleTool.implementationVersionForTests = 1 }

        SampleTool.implementationVersionForTests = 1
        let first = try tool.buildCacheKeyFromAllInputs(input: input)

        SampleTool.implementationVersionForTests = 2
        let second = try tool.buildCacheKeyFromAllInputs(input: input)

        SampleTool.implementationVersionForTests = 1
        let firstAgain = try tool.buildCacheKeyFromAllInputs(input: input)

        XCTAssertNotEqual(first, second, "the implementation that produced an entry belongs in its key")
        XCTAssertEqual(first, firstAgain, "the same implementation keys the same way")
    }

    /// What a per-node constant buys over a version stamped on the whole engine: a bump
    /// invalidates the entries of the one type whose output changed, and every other type
    /// keeps hitting.
    func test_aBumpedVersionMissesWhileATypeAtTheSameVersionHits() throws {
        defer { SampleTool.implementationVersionForTests = 1 }
        let tool  = try makeCompilerNode()
        let input = try makeInput()
        let (otherRecord, _) = try GraphSpecNode.parse("OtherSampleTool()").findOrCreateMatchingNode()
        let other = try OtherSampleTool(thisNode: otherRecord)

        let toolKey  = try XCTUnwrap(tool.buildCacheKeyFromAllInputs(input: input))
        let otherKey = try XCTUnwrap(other.buildCacheKeyFromAllInputs(input: input))
        try tool.saveCacheForAllInputsAndOutputs(cacheKey: toolKey, processingDuration: 0.1,
                                                 output: builtOutput())
        try other.saveCacheForAllInputsAndOutputs(cacheKey: otherKey, processingDuration: 0.1,
                                                  output: builtOutput())

        SampleTool.implementationVersionForTests = 2

        let keyAfterTheBump = try XCTUnwrap(tool.buildCacheKeyFromAllInputs(input: input))
        XCTAssertNil(try tool.loadCachedOutputs(cacheKey: keyAfterTheBump),
                     "a bumped type hits nothing its older implementation left")
        XCTAssertEqual(try other.buildCacheKeyFromAllInputs(input: input), otherKey,
                       "one type's bump does not move another type's key")
        XCTAssertNotNil(try other.loadCachedOutputs(cacheKey: otherKey),
                        "a type whose output did not change keeps its entries")
    }

    /// A node type says nothing about its implementation until its output changes, so the
    /// shipped types carry no version of their own.
    func test_aNodeTypeThatDeclaresNoVersionIsAtOne() {
        XCTAssertEqual(OtherSampleTool.implementationVersion, 1)
    }

    // MARK: - What a stored entry still means

    /// An entry carries the specs its node demanded, and a spec names node types by name.
    /// A Semel that does not link a named type cannot replay such a spec, so the entry is a
    /// miss: the node recomputes and demands what this Semel can make, rather than failing
    /// on a type nothing can build. The node's own `implementationVersion` cannot cover
    /// this — the type that went is somebody else's.
    func test_anEntryDemandingATypeThisSemelDoesNotLinkIsAMiss() throws {
        let tool = try makeCompilerNode()
        let key  = try XCTUnwrap(tool.buildCacheKeyFromAllInputs(input: try makeInput()))
        let output = ProcessOutput(
            outputValues: [SampleTool.output: .value(try "OBJECT".intern())],
            inputWireSpecs: [SampleTool.input: ["wire0": "RetiredSampleTool(path: 'input:/x.c').output"]])
        try tool.saveCacheForAllInputsAndOutputs(cacheKey: key, processingDuration: 0.1, output: output)

        XCTAssertNil(try tool.loadCachedOutputs(cacheKey: key),
                     "a spec naming a type this Semel cannot make is not an entry to hand back")
    }

    /// The retired type can sit anywhere in the demanded subgraph, so the whole spec tree
    /// is read and not only the node at its root.
    func test_anEntryDemandingARetiredTypeDeeperInASpecIsAMissToo() throws {
        let tool = try makeCompilerNode()
        let key  = try XCTUnwrap(tool.buildCacheKeyFromAllInputs(input: try makeInput()))
        let spec = "Configuration(role: 'x', input: [\"a\": RetiredSampleTool().output]).output"
        let output = ProcessOutput(
            outputValues: [SampleTool.output: .value(try "OBJECT".intern())],
            inputWireSpecs: [SampleTool.input: ["wire0": spec]])
        try tool.saveCacheForAllInputsAndOutputs(cacheKey: key, processingDuration: 0.1, output: output)

        XCTAssertNil(try tool.loadCachedOutputs(cacheKey: key))
    }

    /// The common entry, which every spec of it names a linked type: it comes back.
    func test_anEntryWhoseSpecsNameLinkedTypesIsAHit() throws {
        let tool = try makeCompilerNode()
        let key  = try XCTUnwrap(tool.buildCacheKeyFromAllInputs(input: try makeInput()))
        let output = ProcessOutput(
            outputValues: [SampleTool.output: .value(try "OBJECT".intern())],
            inputWireSpecs: [SampleTool.input: ["wire0": "StaticFile(path: 'input:/x.c').output"]])
        try tool.saveCacheForAllInputsAndOutputs(cacheKey: key, processingDuration: 0.1, output: output)

        let loaded = try XCTUnwrap(tool.loadCachedOutputs(cacheKey: key))
        XCTAssertEqual(loaded.inputWireSpecs[SampleTool.input]?["wire0"],
                       "StaticFile(path: 'input:/x.c').output")
    }

    // MARK: - What a node reads from outside its inputs

    /// B-47. A tool that reads the machine — the Swift tools compile against whatever is
    /// behind `-sdk` — declares a fingerprint of what it read through `cacheKeyMaterial`,
    /// and the key changes with it. Nil, the default, adds nothing, which is what keeps
    /// the pinned key format above intact for every node that has no such material.
    func test_aNodesCacheKeyMaterialIsPartOfTheKey() throws {
        let tool = try makeCompilerNode()
        let input = try makeInput()
        defer { SampleTool.cacheKeyMaterialForTests = nil }

        SampleTool.cacheKeyMaterialForTests = nil
        let without = try tool.buildCacheKeyFromAllInputs(input: input)

        SampleTool.cacheKeyMaterialForTests = "sdk=abc"
        let withOne = try tool.buildCacheKeyFromAllInputs(input: input)

        SampleTool.cacheKeyMaterialForTests = "sdk=def"
        let withAnother = try tool.buildCacheKeyFromAllInputs(input: input)

        SampleTool.cacheKeyMaterialForTests = "sdk=abc"
        let withOneAgain = try tool.buildCacheKeyFromAllInputs(input: input)

        XCTAssertNotEqual(without, withOne, "material the node reads belongs in the key")
        XCTAssertNotEqual(withOne, withAnother, "different material, different key")
        XCTAssertEqual(withOne, withOneAgain, "the same material gives the same key")
    }

    // MARK: - The tool binary behind a descriptor

    /// Installs a registry holding one tool of the version `configuration()` names, under
    /// the fingerprint discovery would have taken of the binary behind it.
    private func installTool(fingerprint: String?) {
        let registry = ToolRunnerRegistry()
        registry.registerTool(descriptor: .init(name: "sample",
                                                version: "sample tool version 1",
                                                platform: "macOS",
                                                architecture: "arm64",
                                                recursiveHash: fingerprint),
                              toolExecutor: RecordingToolRunner())
        ToolRunnerRegistry.instance = registry
    }

    /// B-17. A version string is what a binary says about itself, and two binaries say the
    /// same thing: a locally built compiler and the release it calls itself, the same
    /// toolchain version reinstalled with a patch. The configuration cannot tell them
    /// apart — it names a version — so the fingerprint of the binary that will run is in
    /// the key, and a node built by one does not come back for the other.
    func test_twoBinariesOfOneToolVersionDoNotShareACacheKey() throws {
        let tool  = try makeCompilerNode()
        let input = try makeInput()

        installTool(fingerprint: "fingerprint-of-one-binary")
        let withOne = try tool.buildCacheKeyFromAllInputs(input: input)

        installTool(fingerprint: "fingerprint-of-another-binary")
        let withAnother = try tool.buildCacheKeyFromAllInputs(input: input)

        installTool(fingerprint: "fingerprint-of-one-binary")
        let withOneAgain = try tool.buildCacheKeyFromAllInputs(input: input)

        XCTAssertNotEqual(withOne, withAnother,
                          "two binaries reporting one version must not share an entry")
        XCTAssertEqual(withOne, withOneAgain,
                       "one binary, one key: the fingerprint is the only thing that moved")
    }

    /// The identity in the configuration still decides *which* tool a node runs, so a node
    /// naming a tool the machine does not have takes no fingerprint into its key — it
    /// fails when it is processed, with a message naming what is installed.
    func test_aToolThatIsNotInstalledContributesNoFingerprint() throws {
        let tool  = try makeCompilerNode()
        let input = try makeInput()

        ToolRunnerRegistry.instance = ToolRunnerRegistry()
        let withoutTheTool = try tool.buildCacheKeyFromAllInputs(input: input)

        installTool(fingerprint: nil)
        let withAToolThatHasNoFingerprint = try tool.buildCacheKeyFromAllInputs(input: input)

        installTool(fingerprint: "fingerprint-of-one-binary")
        let withAFingerprintedTool = try tool.buildCacheKeyFromAllInputs(input: input)

        XCTAssertEqual(withoutTheTool, withAToolThatHasNoFingerprint)
        XCTAssertNotEqual(withoutTheTool, withAFingerprintedTool,
                          "a fingerprint that is there is in the key — without this the test "
                          + "would pass with the whole mechanism removed")
    }

    // MARK: - Round trip

    func test_savedOutputsComeBackForTheSameKey() throws {
        let tool = try makeCompilerNode()
        let input = try makeInput()
        let key = try XCTUnwrap(tool.buildCacheKeyFromAllInputs(input: input))

        let output = ProcessOutput(
            outputValues: [SampleTool.output: .value(try "OBJECT".intern()),
                           SampleTool.errorLog: .value(""),
                           SampleTool.infoLog: .value("")],
            inputWireSpecs: [:])
        try tool.saveCacheForAllInputsAndOutputs(cacheKey: key, processingDuration: 0.1, output: output)

        let loaded = try XCTUnwrap(tool.loadCachedOutputs(cacheKey: key))
        XCTAssertEqual(try loaded.outputValues[SampleTool.output]?.expectValue().resolveAsString(),
                       "OBJECT")
    }

    func test_aDifferentKeyIsAMiss() throws {
        let tool = try makeCompilerNode()
        let key = try XCTUnwrap(tool.buildCacheKeyFromAllInputs(input: try makeInput()))

        let output = ProcessOutput(
            outputValues: [SampleTool.output: .value(try "OBJECT".intern()),
                           SampleTool.errorLog: .value(""),
                           SampleTool.infoLog: .value("")],
            inputWireSpecs: [:])
        try tool.saveCacheForAllInputsAndOutputs(cacheKey: key, processingDuration: 0.1, output: output)

        let otherKey = try XCTUnwrap(
            tool.buildCacheKeyFromAllInputs(input: try makeInput(contents: "different source")))

        XCTAssertNil(try tool.loadCachedOutputs(cacheKey: otherKey))
    }

    // A node whose inputs are not all present must not silently key on a partial set —
    // and must not take the process down either.
    func test_aMissingInputPortIsReportedRatherThanCrashing() throws {
        let tool = try makeCompilerNode()
        let partial = ProcessInput(inputValues: [
            SampleTool.configuration: ["configuration": .value(try configuration().intern())],
        ])

        XCTAssertThrowsError(try tool.buildCacheKeyFromAllInputs(input: partial))
    }
}
