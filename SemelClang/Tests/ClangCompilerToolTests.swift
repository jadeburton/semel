//
//  ClangCompilerToolTests.swift
//  build_system_tests
//
//  The tool wrappers' real work is assembling a command line and mapping the result onto
//  output ports. A recording executor makes both observable without running a compiler.
//

@testable import SemelClang
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class ClangCompilerToolTests: SemelClangTestCase {

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

    private func makeTool() throws -> ClangCompilerTool {
        try ClangCompilerTool(thisNode: Node(id: 1, kind: ClangCompilerTool.kind))
    }

    private func makeInput(sourcePath: String = "src/hello.c.p",
                           contents: String = "int main(){}",
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
            ClangCompilerTool.configuration: ["configuration": .value(try configuration.intern())],
            ClangCompilerTool.input: [sourcePath: .value(try contents.intern())],
        ])
    }

    // MARK: - Command line

    func test_compilesTheInputAsCToAnObjectFileForTheTargetArchitecture() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.c.p"))

        XCTAssertEqual(executor.lastArguments,
                       ["-x", "c",
                        "-c", "src/hello.c.p",
                        "-o", "src/hello.c.p.o",
                        "-target", "arm64-apple-macos14.0"])
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
        XCTAssertThrowsError(try makeTool().process(input: try makeInput(sourcePath: "src/hello.cpp.p"))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("clang.compiler.std"), "got \(message)")
        }
    }

    func test_aCPlusPlusSourceUsesTheStandardTheConfigurationStates() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.cpp.p", std: "c++20"))

        XCTAssertTrue(executor.lastArguments.contains("-std=c++20"), "got \(executor.lastArguments)")
    }

    /// C is left alone. Its standard is still honoured when stated, but a C file with none
    /// is a complete configuration -- so requiring one would make a mixed C/C++ project,
    /// which has only the one `clang.compiler.std` to say it with, unbuildable.
    func test_aCSourceStillUsesTheStandardTheConfigurationStates() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.c.p", std: "c17"))

        XCTAssertTrue(executor.lastArguments.contains("-std=c17"), "got \(executor.lastArguments)")
    }

    // MARK: - Tool inputs

    func test_passesTheSourceFileToTheToolAsAnInput() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "a/b/c.p"))

        XCTAssertEqual(executor.invocations.first?.inputFileNames, ["a/b/c.p"])
        XCTAssertEqual(executor.invocations.first?.expectedOutputFileNames, ["a/b/c.p.o"])
    }

    // MARK: - Result mapping

    func test_successfulRunPublishesTheObjectFileOnTheOutputPort() throws {
        executor.producedFiles = ["src/hello.c.p.o": Array("OBJECT-BYTES".utf8)]

        let output = try makeTool().process(input: try makeInput())

        let value = try XCTUnwrap(output.outputValues[ClangCompilerTool.output])
        XCTAssertEqual(try value.expectValue().resolveAsString(), "OBJECT-BYTES")
    }

    func test_missingToolNamesWhatWasRequestedAndWhatIsRegistered() throws {
        ToolExecutorRegistry.instance = ToolExecutorRegistry()

        XCTAssertThrowsError(try makeTool().process(input: try makeInput())) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("clang"), "should name the requested tool, got \(message)")
            XCTAssertTrue(message.contains("no tools are registered"),
                          "should say what is available, got \(message)")
        }
    }
}
