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
                           arguments: String? = nil,
                           defines: String? = nil,
                           otherSettings: [String: String] = [:]) throws -> ProcessInput {
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
        if let defines     { configuration += "\ndefines=\(defines)" }
        for (key, value) in otherSettings.sorted(by: { $0.key < $1.key }) {
            configuration += "\n\(key)=\(value)"
        }
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

    /// A package target's `.define` settings arrive as `defines` (B-55), a key of their
    /// own so that stating them does not replace the project's `arguments`: each is a `-D`,
    /// and they come before `arguments`, where a project's own flag can still undo one.
    func test_eachDefineIsADashDBeforeTheArguments() throws {
        _ = try makeTool().process(input: try makeInput(arguments: "-UFOO", defines: "FOO,BAR=2"))

        XCTAssertEqual(Array(executor.lastArguments.suffix(3)), ["-DFOO", "-DBAR=2", "-UFOO"])

        _ = try makeTool().process(input: try makeInput())
        XCTAssertFalse(executor.lastArguments.contains { $0.hasPrefix("-D") }, "\(executor.lastArguments)")
    }

    // MARK: - Modules and ARC (B-77)

    // An Objective-C target in a Swift package is built as SwiftPM builds it: its headers
    // open with `@import Foundation;`, which needs modules, and its code assumes ARC, which
    // the preprocessor sees through `__has_feature(objc_arc)` (FMDB's retain macros). The
    // converter states both as settings; the node decides per file what they mean.

    private let objectiveCSettings = ["modules": "true", "objectiveCARC": "true", "moduleName": "Kit"]

    func test_anObjectiveCSourceIsPreprocessedWithARCAndModulesCachedInsideTheSandbox() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/Kit.m", otherSettings: objectiveCSettings))

        let arguments = executor.lastArguments
        XCTAssertTrue(arguments.contains("-fobjc-arc"), "\(arguments)")
        XCTAssertTrue(arguments.contains("-fmodules"), "\(arguments)")
        XCTAssertTrue(arguments.contains("-fmodule-name=Kit"), "\(arguments)")
        // Relative, so it is below the sandbox and names nothing outside it.
        XCTAssertTrue(arguments.contains("-fmodules-cache-path=\(ToolSandbox.derivedStateFolderName)/clang-module-cache"),
                      "\(arguments)")
    }

    /// ARC is Objective-C's and Objective-C++'s, and modules Objective-C's alone: loaded
    /// again by the compiler, a module's macros expand a second time in text the
    /// preprocessor already expanded, and only Objective-C writes `@import`, so only it
    /// needs them. The SDK's `#define ts_64 uts.ts_64` broke PLCrashReporter's C that way.
    func test_eachLanguageTakesOnlyTheFlagsThatApplyToIt() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/plain.c", otherSettings: objectiveCSettings))
        XCTAssertFalse(executor.lastArguments.contains("-fobjc-arc"), "\(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("-fmodules"), "\(executor.lastArguments)")

        _ = try makeTool().process(input: try makeInput(sourcePath: "src/bridge.mm", cxxStandard: "c++17",
                                                        otherSettings: objectiveCSettings))
        XCTAssertTrue(executor.lastArguments.contains("-fobjc-arc"), "\(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("-fmodules"), "\(executor.lastArguments)")
    }

    /// What `clang -E -fmodules -fmodule-name=Kit` writes for a source including a header
    /// its target's own `include/module.modulemap` covers (CodeEditTextViewObjC's), cut down.
    private let preprocessedWithOwnModule = """
        # 1 "src/Kit.m"
        #pragma clang module import Foundation /* clang -E: implicit import for #import <Foundation/Foundation.h> */
        # 1 "include/Kit.h" 1
        #pragma clang module begin Kit
        #pragma clang module import Foundation /* clang -E: implicit import for #import <Foundation/Foundation.h> */
        void KitHello(void);
        #pragma clang module end /*Kit*/
        # 3 "src/Kit.m" 2
        void KitHello(void) { NSLog(@"hi"); }

        """

    /// The compiler, handed preprocessed text alone, cannot enter the module the two pragmas
    /// mark (`must specify '-fmodule-name'`, and with it `no module map available`), so the
    /// target's own module is handed on as the text it is (B-77). Imports stay, and so does
    /// what was between the pragmas.
    func test_theTargetsOwnModuleIsHandedOnAsText() throws {
        executor.producedFiles["src/Kit.m.p"] = Array(preprocessedWithOwnModule.utf8)
        let output = try makeTool().process(input: try makeInput(sourcePath: "src/Kit.m", otherSettings: objectiveCSettings))

        let text = try XCTUnwrap(output.outputValues[ClangPreprocessor.output]).expectValue().resolveAsString()
        XCTAssertEqual(text, """
            # 1 "src/Kit.m"
            #pragma clang module import Foundation /* clang -E: implicit import for #import <Foundation/Foundation.h> */
            # 1 "include/Kit.h" 1
            #pragma clang module import Foundation /* clang -E: implicit import for #import <Foundation/Foundation.h> */
            void KitHello(void);
            # 3 "src/Kit.m" 2
            void KitHello(void) { NSLog(@"hi"); }

            """)
    }

    /// Only the target's own module, a submodule of it included, and each end with its own
    /// begin; bytes that are not UTF-8 pass through untouched. Without modules, or for a
    /// language that loads none, the output is clang's as it stands.
    func test_onlyTheOwnModulesPragmasAreTakenOut() throws {
        let text = Array("#pragma clang module begin Kit.Private\na\n#pragma clang module begin Other\nb\n".utf8)
            + [0xFF, 0x0A]
            + Array("#pragma clang module end /*Other*/\n#pragma clang module end /*Kit.Private*/\n#pragma clang module begin Kitchen\nc\n#pragma clang module end /*Kitchen*/\n".utf8)
        let kept = ClangPreprocessor.ownModuleAsText(text, moduleName: "Kit")

        XCTAssertEqual(kept, Array("a\n#pragma clang module begin Other\nb\n".utf8) + [0xFF, 0x0A]
                           + Array("#pragma clang module end /*Other*/\n#pragma clang module begin Kitchen\nc\n#pragma clang module end /*Kitchen*/\n".utf8))

        executor.producedFiles["src/plain.c.p"] = Array(preprocessedWithOwnModule.utf8)
        let plain = try makeTool().process(input: try makeInput(sourcePath: "src/plain.c", otherSettings: objectiveCSettings))
        XCTAssertEqual(try XCTUnwrap(plain.outputValues[ClangPreprocessor.output]).expectValue().resolveAsString(),
                       preprocessedWithOwnModule)
    }

    /// A hand-written formula's Objective-C is compiled as it always was: neither flag is
    /// Semel's choice to make for it.
    func test_withoutTheSettingsAnObjectiveCSourceTakesNeitherFlag() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/Kit.m"))

        XCTAssertFalse(executor.lastArguments.contains("-fobjc-arc"), "\(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains { $0.hasPrefix("-fmodule") }, "\(executor.lastArguments)")
    }

    func test_aSettingThatIsNeitherTrueNorFalseFailsNamingItsKey() throws {
        XCTAssertThrowsError(try makeTool().process(input: try makeInput(sourcePath: "src/Kit.m",
                                                                        otherSettings: ["objectiveCARC": "yes"]))) { error in
            XCTAssertTrue(String(describing: error).contains("clang.preprocessor.objectiveCARC"), "\(error)")
        }
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
        for reason in [NoValueReason.inputInError, .deleted, .error(documentHash: try "broken".intern())] {
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
    // carries clang's text, and the key behind it as the remedy.

    private func failureDocument(_ output: ProcessOutput, port: String) throws -> ErrorDocument {
        try XCTUnwrap(output.outputValues[port]?.errorDocument,
                      "expected an error on \(port), got \(String(describing: output.outputValues[port]))")
    }

    func test_aTripleClangRejectsIsReportedWithTheSettingItCameFrom() throws {
        executor.exitCode = 1
        executor.errorOutput = "error: unknown target triple 'nonsense-triple'"

        let output = try makeTool().process(input: try makeInput(target: "nonsense-triple"))

        XCTAssertEqual(try failureDocument(output, port: ClangPreprocessor.output),
                       ErrorDocument(diagnostic: .tool(text: "error: unknown target triple 'nonsense-triple'", tool: "clang"),
                                     subject: .source(path: "src/hello.c"),
                                     remedy: .setting(keys: ["clang.preprocessor.target"])))
    }

    func test_anSDKPathClangCannotFindIsReportedWithTheSettingItCameFrom() throws {
        executor.exitCode = 1
        executor.errorOutput = """
            clang: warning: no such sysroot directory: '/no/such/sdk' [-Wmissing-sysroot]
            src/hello.c:1:10: fatal error: 'stdio.h' file not found
            """

        let output = try makeTool().process(input: try makeInput(sdkPath: "/no/such/sdk"))

        XCTAssertEqual(try failureDocument(output, port: ClangPreprocessor.output).remedy,
                       .setting(keys: ["clang.preprocessor.sdkPath"]))
    }

    /// An ordinary compile error is about the source, not the command line, and gains
    /// nothing: a remedy naming the target under every broken file would be noise.
    func test_anErrorInTheSourceNamesNoSetting() throws {
        executor.exitCode = 1
        executor.errorOutput = "src/hello.c:1:1: error: unknown type name 'itn'"

        let output = try makeTool().process(input: try makeInput())

        let document = try failureDocument(output, port: ClangPreprocessor.output)
        XCTAssertEqual(document.diagnostic, .tool(text: "src/hello.c:1:1: error: unknown type name 'itn'", tool: "clang"))
        XCTAssertNil(document.remedy)
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
        XCTAssertEqual(ClangPreprocessor.language(for: "a.S"),     "assembler-with-cpp", "uppercase .S is preprocessed")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.S.p"),   "assembler-with-cpp")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.s"),     "assembler")
        XCTAssertEqual(ClangPreprocessor.language(for: "a.s.o"),   "assembler")
    }

    /// A `.S` is assembly with macros and `#include`s (PLCrashReporter's
    /// `PLCrashAsyncThread_current.S`, B-55): preprocessed as such, with the target's
    /// defines, and with no language standard, which assembly has none of — so a
    /// configuration naming no standard at all preprocesses it.
    func test_preprocessesAssemblyAsAssemblyWithNoStandard() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/thread.S", cStandard: nil, defines: "PLCR_PRIVATE"))

        let arguments = executor.lastArguments
        XCTAssertEqual(Array(arguments.prefix(3)), ["-E", "-x", "assembler-with-cpp"])
        XCTAssertFalse(arguments.contains { $0.hasPrefix("-std=") }, "got \(arguments)")
        XCTAssertTrue(arguments.contains("-DPLCR_PRIVATE"), "got \(arguments)")
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

    /// The tree of each folder in `roots`, as a `Folder` publishes it (B-135), folded from
    /// the listings of every folder in `roots` and `below`, by path.
    private func trees(of roots: [String: NodeValue], below: [String: NodeValue] = [:]) throws -> [String: NodeValue] {
        var listings: [String: [FolderManifestEntry]] = [:]
        for (path, value) in roots.merging(below, uniquingKeysWith: { first, _ in first }) {
            let listing: FolderManifest = try TypeRegistry.decodeAndCast(encodedJSON: try value.expectValue().resolveAsString())
            listings[path] = listing.entries
        }
        var trees: [String: NodeValue] = [:]
        for path in roots.keys {
            trees[path] = .value(try FolderSubtreeManifest.folding(at: path, listings: listings).toJSON().intern())
        }
        return trees
    }

    private var headerFolders: [String: NodeValue] {
        get throws {
            ["input:/pkg/src":         try folderManifest("input:/pkg/src", files: ["blocks.c", "parser.h"], folders: ["include"]),
             "input:/pkg/src/include": try folderManifest("input:/pkg/src/include", files: ["cmark.h", "module.modulemap"])]
        }
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
            ClangPreprocessor.configuration:     ["configuration": .value(try configuration.intern())],
            ClangPreprocessor.sourceFileInput:   ["input:/pkg/src/blocks.c": .value(try "int f(void){return 0;}".intern())],
            ClangPreprocessor.includeFileLists:  [:],
            ClangPreprocessor.headerInputFiles:  headerFiles,
            ClangPreprocessor.headerFolders:     try headerFolders,
            ClangPreprocessor.headerFolderTrees: try trees(of: try headerFolders),
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

    // MARK: - Nested header folders (B-55)

    // A header folder is read to the bottom: `include/openssl/ssl.h` is reached by
    // `#include <openssl/ssl.h>` under the `include` search path, and a source in
    // `src/lib/` includes its sibling `"lib.h"` from beside it. Both need the file placed
    // at its input-file-system path, which is where every header input goes already, so
    // what is new is the reading: each header folder's tree, on a port of its own (B-135).

    private var nestedHeaderFolders: [String: NodeValue] {
        get throws {
            ["input:/pkg/src":         try folderManifest("input:/pkg/src", files: ["blocks.c"], folders: ["include", "lib", ".git"]),
             "input:/pkg/src/include": try folderManifest("input:/pkg/src/include", files: ["cmark.h"], folders: ["cmark"])]
        }
    }

    /// With `treesArrived`, each header folder's tree is in, folded from the folders below.
    private func nestedFolderInput(treesArrived: Bool, headerFiles: [String: NodeValue]) throws -> ProcessInput {
        var inputValues = try makeFolderInput(headerFiles: headerFiles).inputValues
        inputValues[ClangPreprocessor.headerFolders] = try nestedHeaderFolders
        inputValues[ClangPreprocessor.headerFolderTrees] = treesArrived ? try trees(of: try nestedHeaderFolders, below: try nestedSubfolders) : [:]
        return ProcessInput(inputValues: inputValues)
    }

    private var nestedSubfolders: [String: NodeValue] {
        get throws {
            ["input:/pkg/src/lib":           try folderManifest("input:/pkg/src/lib", files: ["lib.h", "lib.c"]),
             "input:/pkg/src/include/cmark": try folderManifest("input:/pkg/src/include/cmark", files: ["node.h"]),
             "input:/pkg/src/.git":          try folderManifest("input:/pkg/src/.git", files: ["HEAD"])]
        }
    }

    private let nestedHeaderPaths = ["input:/pkg/src/include/cmark.h", "input:/pkg/src/include/cmark/node.h",
                                     "input:/pkg/src/lib/lib.c", "input:/pkg/src/lib/lib.h"]

    /// The first pass asks for each header folder's tree, and runs nothing.
    func test_aHeaderFoldersTreeIsAskedForBeforeAnythingRuns() throws {
        let output = try makeTool().process(input: try nestedFolderInput(treesArrived: false, headerFiles: [:]))

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[ClangPreprocessor.headerFolderTrees]).keys.sorted(),
                       ["input:/pkg/src", "input:/pkg/src/include"])
        XCTAssertTrue(executor.invocations.isEmpty, "the trees have not arrived")
    }

    /// Once the trees are in, every file below the folders is a header input too, and
    /// nothing in a hidden folder; nothing more is asked for than the trees.
    func test_everyFileBelowAHeaderFolderIsAskedFor() throws {
        let output = try makeTool().process(input: try nestedFolderInput(treesArrived: true, headerFiles: [:]))

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[ClangPreprocessor.headerInputFiles]).keys.sorted(), nestedHeaderPaths)
        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[ClangPreprocessor.headerFolderTrees]).keys.sorted(),
                       ["input:/pkg/src", "input:/pkg/src/include"])
        XCTAssertTrue(executor.invocations.isEmpty, "nothing runs until the headers are on the wire")
    }

    /// With every file on its wire the run places the nested ones at their paths, and
    /// only the folders on `headerFolders` are search paths.
    func test_nestedHeadersArePlacedAtTheirPathsAndOnlyTheGivenFoldersAreSearchPaths() throws {
        var wires: [String: NodeValue] = [:]
        for path in nestedHeaderPaths {
            wires[path] = .value(try "// \(path)".intern())
        }
        _ = try makeTool().process(input: try nestedFolderInput(treesArrived: true, headerFiles: wires))

        let invocation = try XCTUnwrap(executor.invocations.last, "the trees and the files have arrived")
        XCTAssertTrue(invocation.inputFileNames.contains("input:/pkg/src/include/cmark/node.h"), "\(invocation.inputFileNames)")
        XCTAssertTrue(invocation.inputFileNames.contains("input:/pkg/src/lib/lib.h"), "\(invocation.inputFileNames)")
        let arguments = executor.lastArguments
        let includeFlags = zip(arguments, arguments.dropFirst()).filter { $0.0 == "-I" }.map(\.1)
        XCTAssertEqual(includeFlags, [".", "input:/pkg/src", "input:/pkg/src/include"], "got \(arguments)")
    }

    // MARK: - A target's prefix header, header map and frameworks (B-77)

    private func tree(_ paths: [String]) throws -> NodeValue {
        let entries = try paths.sorted().map { path in
            TreeManifestEntry(path: path, hash: try "// \(path)".intern(), mode: 0o644)
        }
        return .value(try TreeManifest(entries: entries).toJSON().intern())
    }

    private func makeTargetInput() throws -> ProcessInput {
        var inputValues = try makeInput(sourcePath: "input:/app/Source/Main.m").inputValues
        inputValues[ClangPreprocessor.prefixHeader] = ["input:/app/Source/App.pch": .value(try "#import <Cocoa/Cocoa.h>".intern())]
        inputValues[ClangPreprocessor.quoteHeaderTrees] = ["input:/app": try tree(["Source/Main.h", "Source/Views/Cell.h", "Source/Main.m"])]
        inputValues[ClangPreprocessor.headerTrees] = ["own": try tree(["App/Main.h"]),
                                                      "generated": try tree(["App-Swift.h"])]
        inputValues[ClangPreprocessor.frameworkTrees] = ["Kit": try tree(["Kit.framework/Headers/Kit.h"])]
        return ProcessInput(inputValues: inputValues)
    }

    /// Xcode's header map, laid out: each folder of the target's header tree holding a file
    /// is an `-iquote`, sorted, so `#import "Cell.h"` finds `Views/Cell.h` from anywhere;
    /// a tree on `headerTrees` is an `-I` at its key, `<App/Main.h>` and the Swift
    /// interface; the frameworks are one `-F`; the prefix header is forced in. Every file
    /// is placed where its flag says, and a file placed twice is placed once.
    func test_aTargetsHeaderMapFrameworksAndPrefixHeaderAreSearchPathsOverPlacedFiles() throws {
        _ = try makeTool().process(input: try makeTargetInput())

        let arguments = executor.lastArguments
        let pairs = zip(arguments, arguments.dropFirst())
        XCTAssertEqual(pairs.filter { $0.0 == "-iquote" }.map(\.1), ["input:/app/Source", "input:/app/Source/Views"], "got \(arguments)")
        XCTAssertEqual(pairs.filter { $0.0 == "-I" }.map(\.1), ["generated", "own", "."], "got \(arguments)")
        XCTAssertEqual(pairs.filter { $0.0 == "-F" }.map(\.1), ["frameworks"], "got \(arguments)")
        XCTAssertEqual(pairs.filter { $0.0 == "-include" }.map(\.1), ["input:/app/Source/App.pch"], "got \(arguments)")
        let placed = try XCTUnwrap(executor.invocations.last).inputFileNames
        for path in ["input:/app/Source/App.pch", "input:/app/Source/Views/Cell.h", "own/App/Main.h", "generated/App-Swift.h",
                     "frameworks/Kit.framework/Headers/Kit.h"] {
            XCTAssertTrue(placed.contains(path), "\(path) is not placed: \(placed)")
        }
        XCTAssertEqual(placed.filter { $0 == "input:/app/Source/Main.m" }.count, 1, "the source is placed once: \(placed)")
    }

    /// With none of the four the command line is what it was.
    func test_withoutTheTargetsHeadersNoSearchPathIsAdded() throws {
        _ = try makeTool().process(input: try makeInput())

        let arguments = executor.lastArguments
        XCTAssertFalse(arguments.contains("-iquote"), "got \(arguments)")
        XCTAssertFalse(arguments.contains("-F"), "got \(arguments)")
        XCTAssertFalse(arguments.contains("-include"), "got \(arguments)")
    }
}
