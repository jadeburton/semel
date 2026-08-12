//
//  ClangCompilerToolTests.swift
//  build_system_tests
//
//  The tool wrappers' real work is assembling a command line and mapping the result onto
//  output ports. A recording executor makes both observable without running a compiler.
//

@testable import BuildSystemCore
import XCTest

final class ClangCompilerToolTests: BuildSystemTestCase {

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
                           contents: String = "int main(){}") throws -> ProcessInput {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            """
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

    func test_failedRunReportsTheExitCodeInsteadOfPublishingAnObject() throws {
        executor.exitCode = 1

        let output = try makeTool().process(input: try makeInput())

        let value = try XCTUnwrap(output.outputValues[ClangCompilerTool.output])
        guard case .noValue(let reason) = value else {
            return XCTFail("a failed compile must not publish a value, got \(value)")
        }
        guard case .error(let message) = reason else {
            return XCTFail("a failed compile is an error, not pending")
        }
        XCTAssertTrue(message.contains("1"), "the exit code should be reported, got \(message)")
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
