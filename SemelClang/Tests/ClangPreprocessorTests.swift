//
//  ClangPreprocessorTests.swift
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

final class ClangPreprocessorTests: SemelClangTestCase {

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

    private func makeTool() throws -> ClangPreprocessor {
        try ClangPreprocessor(thisNode: NodeRecord(id: 1, kind: ClangPreprocessor.kind))
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
            ClangPreprocessor.configuration:    ["configuration": .value(try configuration.intern())],
            ClangPreprocessor.sourceFileInput:   [sourcePath: .value(try "int main(){}".intern())],
            ClangPreprocessor.includeFileLists:  [sourcePath: .value(try "".intern())],
            ClangPreprocessor.headerInputFiles:  [:],
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
        XCTAssertEqual(ClangPreprocessor.language(for: "a.c"),     "c")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.cpp"),   "c++")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.cc"),    "c++")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.cxx"),   "c++")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.c++"),   "c++")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.C"),     "c++", "uppercase .C is C++ by convention")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.CPP"),   "c++")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.m"),     "objective-c")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.mm"),    "objective-c++")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.cpp.p"), "c++")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.C.p.o"), "c++")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.mm.p.o"), "objective-c++")
    }

    // MARK: - Header folders (B-54)

    // A C target inside a Swift package (swift-cmark) includes headers by search path —
    // `#include <parser.h>` from another folder — which the include finder, which resolves
    // quoted includes beside the including file only, cannot see. The generated formula
    // hands the preprocessor the target's folders instead: every file in them is an input
    // and each folder is an `-I`. With folders given, the finder is not used at all.

    private func folderManifest(_ path: String, files: [String], folders: [String] = []) throws -> NodeValue {
        let entries = files.map { FolderManifestEntry(name: $0, isFolder: false, isPinned: true) }
                    + folders.map { FolderManifestEntry(name: $0, isFolder: true, isPinned: true) }
        return .value(try FolderManifest(baseFolderPath: path, entries: entries).toJSON().intern())
    }

    private func makeFolderInput(headerFiles: [String: NodeValue] = [:]) throws -> ProcessInput {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            target=arm64-apple-macos14.0
            cStandard=c17
            """
        return ProcessInput(inputValues: [
            ClangPreprocessor.configuration:   ["configuration": .value(try configuration.intern())],
            ClangPreprocessor.sourceFileInput:  ["input:/pkg/src/blocks.c": .value(try "int f(void){return 0;}".intern())],
            ClangPreprocessor.includeFileLists: [:],
            ClangPreprocessor.headerInputFiles: headerFiles,
            ClangPreprocessor.headerFolders: [
                "input:/pkg/src":         try folderManifest("input:/pkg/src", files: ["blocks.c", "parser.h"], folders: ["include"]),
                "input:/pkg/src/include": try folderManifest("input:/pkg/src/include", files: ["cmark.h", "module.modulemap"]),
            ],
        ])
    }

    private func headerFileWires() throws -> [String: NodeValue] {
        var wires: [String: NodeValue] = [:]
        for path in ["input:/pkg/src/parser.h",
                     "input:/pkg/src/include/cmark.h", "input:/pkg/src/include/module.modulemap"] {
            wires[path] = .value(try "// \(path)".intern())
        }
        return wires
    }

    /// Every file of every folder except the source itself, which is already an input.
    func test_withHeaderFoldersEveryFileInThemIsAskedForAndNoIncludeFinderIsCreated() throws {
        let output = try makeTool().process(input: try makeFolderInput())

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[ClangPreprocessor.headerInputFiles]).keys.sorted(),
                       ["input:/pkg/src/include/cmark.h", "input:/pkg/src/include/module.modulemap",
                        "input:/pkg/src/parser.h"])
        XCTAssertEqual(output.inputWireSpecs[ClangPreprocessor.includeFileLists] ?? [:], [:],
                       "folders replace the finder; got \(output.inputWireSpecs)")
        XCTAssertTrue(executor.invocations.isEmpty, "nothing runs until the headers are on the wire")
    }

    func test_withHeaderFoldersOnTheWireThePreprocessorRunsWithAnIncludeFlagPerFolder() throws {
        _ = try makeTool().process(input: try makeFolderInput(headerFiles: try headerFileWires()))

        let arguments = executor.lastArguments
        let includeFlags = zip(arguments, arguments.dropFirst()).filter { $0.0 == "-I" }.map(\.1)
        XCTAssertEqual(includeFlags, [".", "input:/pkg/src", "input:/pkg/src/include"], "got \(arguments)")
        XCTAssertTrue(try XCTUnwrap(executor.invocations.last).inputFileNames.contains("input:/pkg/src/include/cmark.h"),
                      "every file of every folder is placed in the sandbox")
    }
}
