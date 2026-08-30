//
//  ClangPreprocessorToolTests.swift
//  build_system_tests
//
//  The target triple used to reach the command line as a literal never read from
//  configuration; this covers that it now comes from configuration like everything else.
//

@testable import SemelClang
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class ClangPreprocessorToolTests: SemelClangTestCase {

    private let descriptor = ToolDescriptor(name: "clang",
                                            version: "test-clang",
                                            platform: "macOS",
                                            architecture: "arm64",
                                            recursiveHash: nil)
    private var executor: RecordingToolExecutor!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolExecutor()
        ToolExecutorRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    // MARK: - Helpers

    private func makeTool() throws -> ClangPreprocessorTool {
        try ClangPreprocessorTool(thisNode: Node(id: 1, kind: ClangPreprocessorTool.kind))
    }

    /// No includes: the ClangIncludeFinder result for the source file is present but empty,
    /// which is enough for the preprocessor to proceed without waiting on header wires.
    private func makeInput(sourcePath: String = "src/hello.c",
                           target: String = "arm64-apple-macos14.0") throws -> ProcessInput {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            target=\(target)
            """
        return ProcessInput(inputValues: [
            ClangPreprocessorTool.configuration:    ["configuration": .value(try configuration.intern())],
            ClangPreprocessorTool.sourceFileInput:   [sourcePath: .value(try "int main(){}".intern())],
            ClangPreprocessorTool.includeFileLists:  [sourcePath: .value(try "".intern())],
            ClangPreprocessorTool.headerInputFiles:  [:],
        ])
    }

    // MARK: - Command line

    func test_preprocessesTheInputForTheTargetArchitecture() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.c"))

        let arguments = executor.lastArguments
        XCTAssertTrue(arguments.contains("-target"))
        XCTAssertTrue(arguments.contains("arm64-apple-macos14.0"))
        XCTAssertTrue(arguments.contains("src/hello.c"))
    }

    /// The target triple must come from configuration, not a literal baked into the
    /// tool: a project pinning a different one has no other way to reach the command line.
    func test_targetComesFromConfigurationRatherThanALiteral() throws {
        _ = try makeTool().process(input: try makeInput(target: "x86_64-apple-macos13.0"))

        XCTAssertTrue(executor.lastArguments.contains("x86_64-apple-macos13.0"))
        XCTAssertFalse(executor.lastArguments.contains("arm64-apple-macos14.0"))
    }
}
