//
//  ClangCompilerTests.swift
//  semel_tests
//
//  The tool wrappers' real work is assembling a command line and mapping the result onto
//  output ports. A recording executor makes both observable without running a compiler.
//

@testable import SemelClang
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class ClangCompilerTests: SemelClangTestCase {

    private let descriptor = ToolDescriptor(name: "clang",
                                            version: "test-clang",
                                            platform: "macOS",
                                            architecture: "arm64",
                                            recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    // MARK: - Helpers

    private func makeTool() throws -> ClangCompiler {
        try ClangCompiler(thisNode: NodeRecord(id: 1, kind: ClangCompiler.kind))
    }

    private func makeInput(sourcePath: String = "src/hello.c.p",
                           contents: String = "int main(){}",
                           target: String = "arm64-apple-macos14.0",
                           cStandard: String? = "c17",
                           cxxStandard: String? = nil) throws -> ProcessInput {
        var configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            target=\(target)
            """
        if let cStandard   { configuration += "\ncStandard=\(cStandard)" }
        if let cxxStandard { configuration += "\ncxxStandard=\(cxxStandard)" }
        return ProcessInput(inputValues: [
            ClangCompiler.configuration: ["configuration": .value(try configuration.intern())],
            ClangCompiler.input: [sourcePath: .value(try contents.intern())],
        ])
    }

    // MARK: - Command line

    func test_compilesTheInputAsCToAnObjectFileForTheTargetArchitecture() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.c.p"))

        XCTAssertEqual(executor.lastArguments,
                       ["-x", "c",
                        "-c", "-std=c17",
                        "-fdebug-compilation-dir=/semel",
                        "src/hello.c.p",
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

    /// Debug information records the compilation directory. Told the canonical name, an
    /// object built in one sandbox is byte-identical to the same object built in another.
    func test_recordsTheCanonicalSandboxNameAsTheCompilationDirectory() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.c.p"))

        XCTAssertTrue(executor.lastArguments.contains("-fdebug-compilation-dir=\(ToolSandbox.canonicalRootName)"),
                      "\(executor.lastArguments)")
    }

    // MARK: - The language standard

    // B-48. A language standard belongs per language, not per package: one `std` key could
    // not say `c17` for the `.c` files and `c++20` for the `.cpp` ones. Which standard clang
    // assumes moves between releases for C (gnu99, gnu11, gnu17) exactly as for C++, so both
    // are required — for the language of the file actually being compiled. There is no
    // fallback: a standard baked into Semel would change what a previous build meant the
    // moment Semel is upgraded.

    func test_aCPlusPlusSourceWithNoStandardFailsNamingTheKeyToWrite() throws {
        XCTAssertThrowsError(try makeTool().process(input: try makeInput(sourcePath: "src/hello.cpp.p",
                                                                        cStandard: "c17"))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("clang.compiler.cxxStandard"), "got \(message)")
            XCTAssertFalse(message.contains("cStandard"), "the C standard is present and irrelevant, got \(message)")
        }
    }

    func test_aCSourceWithNoStandardFailsNamingTheKeyToWrite() throws {
        XCTAssertThrowsError(try makeTool().process(input: try makeInput(sourcePath: "src/hello.c.p",
                                                                        cStandard: nil,
                                                                        cxxStandard: "c++20"))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("clang.compiler.cStandard"), "got \(message)")
            XCTAssertFalse(message.contains("cxxStandard"), "the C++ standard is present and irrelevant, got \(message)")
        }
    }

    /// A mixed project states both, and each file gets its own.
    func test_eachLanguageUsesItsOwnStandardFromOneConfiguration() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.cpp.p", cStandard: "c17", cxxStandard: "c++20"))
        XCTAssertTrue(executor.lastArguments.contains("-std=c++20"), "got \(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("-std=c17"), "got \(executor.lastArguments)")

        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.c.p", cStandard: "c17", cxxStandard: "c++20"))
        XCTAssertTrue(executor.lastArguments.contains("-std=c17"), "got \(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("-std=c++20"), "got \(executor.lastArguments)")
    }

    /// The old single key is not read any more. It is not silently honoured either: the
    /// engine's unclaimed-key report names it, and the missing per-language key fails here.
    func test_theOldStdKeyIsNotHonoured() throws {
        var configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            target=arm64-apple-macos14.0
            std=c++20
            """
        configuration += ""
        let input = ProcessInput(inputValues: [
            ClangCompiler.configuration: ["configuration": .value(try configuration.intern())],
            ClangCompiler.input: ["src/hello.cpp.p": .value(try "int main(){}".intern())],
        ])

        XCTAssertThrowsError(try makeTool().process(input: input)) { error in
            XCTAssertTrue(String(describing: error).contains("clang.compiler.cxxStandard"), "got \(error)")
        }
    }

    // MARK: - Which language a file is

    /// Conventionally C++ on case-sensitive systems; lowercasing the path first made it C.
    func test_anUppercaseCSuffixIsCPlusPlus() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.C.p", cxxStandard: "c++20"))

        XCTAssertTrue(executor.lastArguments.contains("c++"), "got \(executor.lastArguments)")
        XCTAssertTrue(executor.lastArguments.contains("-std=c++20"), "got \(executor.lastArguments)")
    }

    func test_objectiveCPlusPlusUsesTheCPlusPlusStandard() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.mm.p", cxxStandard: "c++20"))

        XCTAssertTrue(executor.lastArguments.contains("objective-c++"), "got \(executor.lastArguments)")
        XCTAssertTrue(executor.lastArguments.contains("-std=c++20"), "got \(executor.lastArguments)")
    }

    func test_objectiveCUsesTheCStandard() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.m.p", cStandard: "c17"))

        XCTAssertTrue(executor.lastArguments.contains("objective-c"), "got \(executor.lastArguments)")
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

        let value = try XCTUnwrap(output.outputValues[ClangCompiler.output])
        XCTAssertEqual(try value.expectValue().resolveAsString(), "OBJECT-BYTES")
    }

    func test_missingToolNamesWhatWasRequestedAndWhatIsRegistered() throws {
        ToolRunnerRegistry.instance = ToolRunnerRegistry()

        XCTAssertThrowsError(try makeTool().process(input: try makeInput())) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("clang"), "should name the requested tool, got \(message)")
            XCTAssertTrue(message.contains("no tools are registered"),
                          "should say what is available, got \(message)")
        }
    }
}
