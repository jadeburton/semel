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
    func test_theKeyFormatHasNotDrifted() throws {
        let key = try makeCompilerNode().buildCacheKeyFromAllInputs(input: try makeInput())

        XCTAssertEqual(key, "102e7cf2a0a9219f558f27e4a9051479857dec7e0455e8440469b8e32d920e87")
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
