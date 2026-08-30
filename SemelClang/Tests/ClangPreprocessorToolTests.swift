//
//  ClangPreprocessorToolTests.swift
//  build_system_tests
//
//  The preprocessor's work is a command line, so a recording executor is enough to see all
//  of it. What these cover is that every part of that command line which describes the
//  environment -- the target triple, the language standard -- comes from configuration, and
//  that a missing one is an error naming the key to write rather than a value Semel picked.
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
        try ClangPreprocessorTool(thisNode: NodeRecord(id: 1, kind: ClangPreprocessorTool.kind))
    }

    /// No includes: the ClangIncludeFinder result for the source file is present but empty,
    /// which is enough for the preprocessor to proceed without waiting on header wires.
    private func makeInput(sourcePath: String = "src/hello.c",
                           target: String = "arm64-apple-macos14.0",
                           std: String? = nil) throws -> ProcessInput {
        var configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            target=\(target)
            """
        if let std { configuration += "\nstd=\(std)" }
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

    // MARK: - The language standard

    /// Which standard clang assumes moves between releases, so a C++ file built without one
    /// stated is not reproducible. There is no fallback: a standard baked into Semel would
    /// change what a previous build meant the moment Semel is upgraded.
    func test_aCPlusPlusSourceWithNoStandardFailsNamingTheKeyToWrite() throws {
        XCTAssertThrowsError(try makeTool().process(input: try makeInput(sourcePath: "src/hello.cpp"))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("clang.preprocessor.std"), "got \(message)")
        }
    }

    func test_aCPlusPlusSourceUsesTheStandardTheConfigurationStates() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.cpp", std: "c++20"))

        XCTAssertTrue(executor.lastArguments.contains("-std=c++20"), "got \(executor.lastArguments)")
    }

    /// C is left alone. Its standard is still honoured when stated, but a C file with none
    /// is a complete configuration -- so requiring one would make a mixed C/C++ project,
    /// which has only the one `clang.preprocessor.std` to say it with, unbuildable.
    func test_aCSourceWithNoStandardIsCompleteAndPassesNoStdFlag() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.c"))

        XCTAssertFalse(executor.lastArguments.contains { $0.hasPrefix("-std=") },
                       "got \(executor.lastArguments)")
    }

    func test_aCSourceStillUsesTheStandardTheConfigurationStates() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.c", std: "c17"))

        XCTAssertTrue(executor.lastArguments.contains("-std=c17"), "got \(executor.lastArguments)")
    }
}
