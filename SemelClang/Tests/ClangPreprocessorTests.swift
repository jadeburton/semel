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
                           sdkPath: String? = nil,
                           cStandard: String? = "c17",
                           cxxStandard: String? = nil,
                           arguments: String? = nil) throws -> ProcessInput {
        var configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            target=\(target)
            """
        if let sdkPath     { configuration += "\nsdkPath=\(sdkPath)" }
        if let cStandard   { configuration += "\ncStandard=\(cStandard)" }
        if let cxxStandard { configuration += "\ncxxStandard=\(cxxStandard)" }
        if let arguments   { configuration += "\narguments=\(arguments)" }
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

    /// `clang.preprocessor.arguments`: a project's defines are the preprocessor's to see —
    /// Lua wants `-DLUA_USE_MACOSX` (B-79) — comma-joined, after what the node builds.
    func test_extraArgumentsFromTheConfigurationEndTheCommandLine() throws {
        _ = try makeTool().process(input: try makeInput(arguments: "-DLUA_USE_MACOSX,-DNDEBUG"))

        XCTAssertEqual(Array(executor.lastArguments.suffix(2)), ["-DLUA_USE_MACOSX", "-DNDEBUG"])

        _ = try makeTool().process(input: try makeInput(arguments: nil))
        XCTAssertFalse(executor.lastArguments.contains("-DNDEBUG"))
    }

    // MARK: - A header nobody pushed (B-79)

    // The include finder reads quoted includes without evaluating a conditional, so a
    // source can name a header that exists on no machine this builds on: SQLite's
    // amalgamation includes `windows.h` and a configure step's `sqlite_cfg.h` under `#if`s
    // that are false here. The preprocessor leaves such a header out and lets clang judge.

    private func makeInputNaming(headers: [String: NodeValue]) throws -> ProcessInput {
        let sourcePath = "src/sqlite3.c"
        var inputValues = try makeInput(sourcePath: sourcePath).inputValues
        var includeLists: [String: NodeValue] = [sourcePath: .value(try headers.keys.sorted().joined(separator: "\n").intern())]
        for header in headers.keys {
            includeLists[header] = .value(try "".intern())
        }
        inputValues[ClangPreprocessor.includeFileLists] = includeLists
        inputValues[ClangPreprocessor.headerInputFiles] = headers
        return ProcessInput(inputValues: inputValues)
    }

    func test_aHeaderNobodyPushedIsLeftOutAndThePreprocessorRuns() throws {
        let output = try makeTool().process(input: try makeInputNaming(headers: [
            "src/sqlite3.h":    .value(try "// the API".intern()),
            "src/sqlite_cfg.h": .noValue(reason: .initializing),
        ]))

        let invocation = try XCTUnwrap(executor.invocations.last, "the preprocessor runs")
        XCTAssertTrue(invocation.inputFileNames.contains("src/sqlite3.h"))
        XCTAssertFalse(invocation.inputFileNames.contains("src/sqlite_cfg.h"),
                       "a header that does not exist is not placed in the sandbox")
        XCTAssertFalse(output.outputValues[ClangPreprocessor.output]?.isNoValue ?? true, "got \(output.outputValues)")
        XCTAssertEqual(output.inputWireSpecs[ClangPreprocessor.headerInputFiles]?.keys.sorted(),
                       ["src/sqlite3.h", "src/sqlite_cfg.h"], "the absent header stays wired, so pushing it later reruns this")
    }

    /// Only a file nobody pushed is absent: a header that failed upstream, or one that was
    /// pushed and then removed, still stops the preprocessor.
    func test_aHeaderInErrorOrDeletedStillFails() throws {
        for reason in [NoValueReason.inputInError, .deleted, .error(messageDataObjectHash: try "broken".intern())] {
            XCTAssertThrowsError(try makeTool().process(input: try makeInputNaming(headers: [
                "src/sqlite3.h": .noValue(reason: reason),
            ])), "\(reason)")
        }
        XCTAssertTrue(executor.invocations.isEmpty)
    }

    /// So a report does not name the absent header as a file to push: whether it matters is
    /// in clang's error, when it does.
    func test_theHeaderPortToleratesAnAbsentValueAndNoOtherDoes() {
        XCTAssertTrue(ClangPreprocessor.descriptor.toleratesAbsentValue(onInputPort: ClangPreprocessor.headerInputFiles))
        XCTAssertFalse(ClangPreprocessor.descriptor.toleratesAbsentValue(onInputPort: ClangPreprocessor.sourceFileInput))
        XCTAssertFalse(ClangPreprocessor.descriptor.toleratesAbsentValue(onInputPort: ClangPreprocessor.configuration))
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

    // MARK: - What a rejected argument says (B-98)

    // clang's complaint names the argument it rejected and never the setting that produced
    // it, so the reader is left holding a triple they did not type. The failed output
    // carries clang's line and then the key and value behind it.

    private func failureMessage(_ output: ProcessOutput, port: String) throws -> String {
        guard case .noValue(.error(let hash)) = output.outputValues[port] else {
            XCTFail("expected an error on \(port), got \(String(describing: output.outputValues[port]))")
            return ""
        }
        return try hash.resolveAsString()
    }

    func test_aTripleClangRejectsIsReportedWithTheSettingItCameFrom() throws {
        executor.exitCode = 1
        executor.errorOutput = "error: unknown target triple 'nonsense-triple'"

        let output = try makeTool().process(input: try makeInput(target: "nonsense-triple"))

        let message = try failureMessage(output, port: ClangPreprocessor.output)
        XCTAssertTrue(message.contains("error: unknown target triple 'nonsense-triple'"), "got \(message)")
        XCTAssertTrue(message.contains("`clang.preprocessor.target` is `nonsense-triple`"), "got \(message)")
        XCTAssertTrue(message.contains("clang -print-target-triple"), "got \(message)")
    }

    func test_anSDKPathClangCannotFindIsReportedWithTheSettingItCameFrom() throws {
        executor.exitCode = 1
        executor.errorOutput = """
            clang: warning: no such sysroot directory: '/no/such/sdk' [-Wmissing-sysroot]
            src/hello.c:1:10: fatal error: 'stdio.h' file not found
            """

        let output = try makeTool().process(input: try makeInput(sdkPath: "/no/such/sdk"))

        let message = try failureMessage(output, port: ClangPreprocessor.output)
        XCTAssertTrue(message.contains("`clang.preprocessor.sdkPath` is `/no/such/sdk`"), "got \(message)")
        XCTAssertTrue(message.contains("xcrun --sdk <name> --show-sdk-path"), "got \(message)")
    }

    /// An ordinary compile error is about the source, not the command line, and gains
    /// nothing: a sentence about the target under every broken file would be noise.
    func test_anErrorInTheSourceNamesNoSetting() throws {
        executor.exitCode = 1
        executor.errorOutput = "src/hello.c:1:1: error: unknown type name 'itn'"

        let output = try makeTool().process(input: try makeInput())

        let message = try failureMessage(output, port: ClangPreprocessor.output)
        XCTAssertEqual(message, """
            clang exited with status 1:
            src/hello.c:1:1: error: unknown type name 'itn'
            """)
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
