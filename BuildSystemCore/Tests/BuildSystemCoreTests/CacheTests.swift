//
//  CacheTests.swift
//  build_system_tests
//
//  A wrong cache hit is the worst failure a build system has: the output looks fine.
//  These pin down what does and does not participate in the key.
//

@testable import BuildSystemCore
import XCTest
import SemelNodeKit

final class CacheTests: BuildSystemTestCase {

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

    private func makeCompilerNode() throws -> ClangCompilerTool {
        let shape = try GraphShapeNode.parse("ClangCompilerTool()")
        let (node, _) = try shape.findOrCreateMatchingNode()
        return try ClangCompilerTool(thisNode: node)
    }

    private func configuration(toolVersion: String = "Apple clang version 17.0.0",
                               extra: [String: String] = [:]) -> String {
        var properties = [
            "toolDescriptor.name": "clang",
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
            ClangCompilerTool.configuration: ["configuration": .value(try (config ?? configuration()).intern())],
            ClangCompilerTool.input: [sourcePath: .value(try contents.intern())],
        ])
    }

    // MARK: - Machine-derived inputs

    /// The SDK a node compiles against changes its output, but it is resolved from the
    /// machine at process time rather than arriving on a wire — so nothing put it in the
    /// key. Two machines on different SDKs produced different object files under
    /// identical keys, which is only mild staleness locally and silent corruption once a
    /// cache is shared between developers.
    func test_theSwiftCompilerRecordsItsSDKInTheCacheKey() throws {
        let shape = try GraphShapeNode.parse("SwiftCompilerTool()")
        let (node, _) = try shape.findOrCreateMatchingNode()
        let tool = try SwiftCompilerTool(thisNode: node)

        XCTAssertFalse(tool.cacheKeyEnvironment.isEmpty,
                       "the SDK influences the output, so it must contribute to the key")
    }

    func test_theSwiftLinkerRecordsItsSDKInTheCacheKey() throws {
        let shape = try GraphShapeNode.parse("SwiftLinkerTool()")
        let (node, _) = try shape.findOrCreateMatchingNode()
        let tool = try SwiftLinkerTool(thisNode: node)

        XCTAssertFalse(tool.cacheKeyEnvironment.isEmpty,
                       "the SDK influences the output, so it must contribute to the key")
    }

    /// Pins the key format. A cache key is a promise that identical inputs mean an
    /// identical build, so an unintended change to how it is composed silently discards
    /// every existing entry — and, on a shared cache, does it for everyone. This value was
    /// recorded before the environment hook was added; it must not move when a node
    /// declares no machine-derived inputs.
    func test_theKeyFormatHasNotDrifted() throws {
        let key = try makeCompilerNode().buildCacheKeyFromAllInputs(input: try makeInput())

        XCTAssertEqual(key, "50ff754ae32daaa6087d74d0c1eb7dcb2542570aff56ebfaba9805bf12604779")
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
            input: try makeInput(configuration: configuration(toolVersion: "Apple clang version 17.0.0")))
        let after = try tool.buildCacheKeyFromAllInputs(
            input: try makeInput(configuration: configuration(toolVersion: "Apple clang version 21.0.0")))

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
        let compilerShape = try GraphShapeNode.parse("ClangCompilerTool()")
        let (compilerNode, _) = try compilerShape.findOrCreateMatchingNode()
        let preprocessorShape = try GraphShapeNode.parse("ClangPreprocessorTool()")
        let (preprocessorNode, _) = try preprocessorShape.findOrCreateMatchingNode()

        let compiler = try ClangCompilerTool(thisNode: compilerNode)
        let preprocessor = try ClangPreprocessorTool(thisNode: preprocessorNode)

        let input = try makeInput()
        let compilerKey = try compiler.buildCacheKeyFromAllInputs(input: input)
        let preprocessorKey = try? preprocessor.buildCacheKeyFromAllInputs(input: input)

        XCTAssertNotEqual(compilerKey, preprocessorKey ?? "",
                          "the node type is part of the key")
    }

    // MARK: - Round trip

    func test_savedOutputsComeBackForTheSameKey() throws {
        let tool = try makeCompilerNode()
        let input = try makeInput()
        let key = try XCTUnwrap(tool.buildCacheKeyFromAllInputs(input: input))

        let output = ProcessOutput(
            outputValues: [ClangCompilerTool.output: .value(try "OBJECT".intern()),
                           ClangCompilerTool.errorLog: .value(""),
                           ClangCompilerTool.infoLog: .value("")],
            inputWireExpectations: [:])
        try tool.saveCacheForAllInputsAndOutputs(cacheKey: key, processingDuration: 0.1, output: output)

        let loaded = try XCTUnwrap(tool.loadCachedOutputs(cacheKey: key))
        XCTAssertEqual(try loaded.outputValues[ClangCompilerTool.output]?.expectValue().resolveAsString(),
                       "OBJECT")
    }

    func test_aDifferentKeyIsAMiss() throws {
        let tool = try makeCompilerNode()
        let key = try XCTUnwrap(tool.buildCacheKeyFromAllInputs(input: try makeInput()))

        let output = ProcessOutput(
            outputValues: [ClangCompilerTool.output: .value(try "OBJECT".intern()),
                           ClangCompilerTool.errorLog: .value(""),
                           ClangCompilerTool.infoLog: .value("")],
            inputWireExpectations: [:])
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
            ClangCompilerTool.configuration: ["configuration": .value(try configuration().intern())],
        ])

        XCTAssertThrowsError(try tool.buildCacheKeyFromAllInputs(input: partial))
    }
}
