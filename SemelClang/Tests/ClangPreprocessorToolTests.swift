//
//  ClangPreprocessorToolTests.swift
//  semel_tests
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
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    // MARK: - Helpers

    private func makeTool() throws -> ClangPreprocessorTool {
        try ClangPreprocessorTool(thisNode: NodeRecord(id: 1, kind: ClangPreprocessorTool.kind))
    }

    /// No includes: the ClangIncludeFinder result for the source file is present but empty,
    /// which is enough for the preprocessor to proceed without waiting on header wires.
    private func makeInput(sourcePath: String = "src/hello.c",
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

    // B-48: one key per language, each required for the language of the file at hand. See
    // ClangCompilerToolTests for the reasoning; the preprocessor takes the same settings
    // under its own namespace.

    func test_aCPlusPlusSourceWithNoStandardFailsNamingTheKeyToWrite() throws {
        XCTAssertThrowsError(try makeTool().process(input: try makeInput(sourcePath: "src/hello.cpp"))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("clang.preprocessor.cxxStandard"), "got \(message)")
        }
    }

    func test_aCSourceWithNoStandardFailsNamingTheKeyToWrite() throws {
        XCTAssertThrowsError(try makeTool().process(input: try makeInput(sourcePath: "src/hello.c",
                                                                        cStandard: nil))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("clang.preprocessor.cStandard"), "got \(message)")
        }
    }

    func test_eachLanguageUsesItsOwnStandardFromOneConfiguration() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.cpp", cStandard: "c17", cxxStandard: "c++20"))
        XCTAssertTrue(executor.lastArguments.contains("-std=c++20"), "got \(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("-std=c17"), "got \(executor.lastArguments)")

        _ = try makeTool().process(input: try makeInput(sourcePath: "src/hello.c", cStandard: "c17", cxxStandard: "c++20"))
        XCTAssertTrue(executor.lastArguments.contains("-std=c17"), "got \(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("-std=c++20"), "got \(executor.lastArguments)")
    }

    // MARK: - Which language a file is

    /// The suffix table is consulted at every stage — raw source here, `.p` in the compiler,
    /// `.p.o` in the linker — so it is pinned once, on the raw forms.
    func test_classifiesSourceFilesByTheirSuffix() {
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.c"),     "c")
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.cpp"),   "c++")
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.cc"),    "c++")
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.cxx"),   "c++")
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.c++"),   "c++")
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.C"),     "c++", "uppercase .C is C++ by convention")
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.CPP"),   "c++")
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.m"),     "objective-c")
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.mm"),    "objective-c++")
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.cpp.p"), "c++")
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.C.p.o"), "c++")
        XCTAssertEqual(ClangPreprocessorTool.language(for: "a.mm.p.o"), "objective-c++")
    }
}
