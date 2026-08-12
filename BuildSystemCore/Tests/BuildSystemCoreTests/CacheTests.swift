//
//  CacheTests.swift
//  build_system_tests
//
//  A wrong cache hit is the worst failure a build system has: the output looks fine.
//  These pin down what does and does not participate in the key.
//

@testable import BuildSystemCore
import XCTest

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
