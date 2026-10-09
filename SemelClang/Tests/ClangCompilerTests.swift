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
                           cxxStandard: String? = nil,
                           arguments: String? = nil,
                           otherSettings: [String: String] = [:]) throws -> ProcessInput {
        var configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            target=\(target)
            """
        if let cStandard   { configuration += "\ncStandard=\(cStandard)" }
        if let cxxStandard { configuration += "\ncxxStandard=\(cxxStandard)" }
        if let arguments   { configuration += "\narguments=\(arguments)" }
        for (key, value) in otherSettings.sorted(by: { $0.key < $1.key }) {
            configuration += "\n\(key)=\(value)"
        }
        return ProcessInput(inputValues: [
            ClangCompiler.configuration: ["configuration": .value(try configuration.intern())],
            ClangCompiler.input: [sourcePath: .value(try contents.intern())],
        ])
    }

    /// `clang.compiler.arguments`: the project's extra flags, comma-joined, after what the
    /// node builds itself, so a project can say `-Wno-parentheses-equality` about its
    /// preprocessed text (B-79).
    func test_extraArgumentsFromTheConfigurationEndTheCommandLine() throws {
        _ = try makeTool().process(input: try makeInput(arguments: "-Wno-parentheses-equality,-O2"))

        XCTAssertEqual(Array(executor.lastArguments.suffix(2)), ["-Wno-parentheses-equality", "-O2"])

        _ = try makeTool().process(input: try makeInput(arguments: nil))
        XCTAssertFalse(executor.lastArguments.contains("-O2"))
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

    // MARK: - Modules and ARC (B-77)

    // Preprocessed Objective-C with modules still says `@import Foundation;`: the imports
    // survive `-E`, so the compiler loads the modules again, from the SDK, into a cache of
    // its own inside the sandbox. ARC is a property of code generation, so the compiler
    // needs it as much as the preprocessor does.

    func test_anObjectiveCSourceWithModulesIsCompiledAgainstTheSDKWithARC() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/Kit.m.p",
                                                        otherSettings: ["modules": "true", "objectiveCARC": "true",
                                                                        "sdkPath": "/SDKs/MacOSX.sdk"]))

        let arguments = executor.lastArguments
        XCTAssertTrue(arguments.contains("-fobjc-arc"), "\(arguments)")
        XCTAssertTrue(arguments.contains("-fmodules"), "\(arguments)")
        XCTAssertTrue(arguments.contains("-fmodules-cache-path=\(ToolSandbox.derivedStateFolderName)/clang-module-cache"),
                      "\(arguments)")
        XCTAssertEqual(arguments.firstIndex(of: "-isysroot").map { arguments[$0 + 1] }, "/SDKs/MacOSX.sdk")
        // The target's own headers are already text in what the preprocessor handed on.
        XCTAssertFalse(arguments.contains { $0.hasPrefix("-fmodule-name") }, "\(arguments)")
    }

    /// Without the SDK the compile would fail as `module 'Foundation' not found`, far from
    /// the cause; a missing machine setting names itself and the command that writes it.
    func test_modulesWithoutAnSDKPathFailNamingTheMachineSetting() throws {
        XCTAssertThrowsError(try makeTool().process(input: try makeInput(sourcePath: "src/Kit.m.p",
                                                                        otherSettings: ["modules": "true"]))) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("clang.compiler.sdkPath"), message)
            XCTAssertTrue(message.contains("semel-clang"), message)
        }
    }

    /// Only Objective-C loads modules; a C++ or C source of the same target needs no SDK,
    /// as ever. Loaded again here, a module's self-referential macro — the SDK's
    /// `#define ts_64 uts.ts_64` — would expand a second time in C the preprocessor had
    /// already expanded, which is how PLCrashReporter's thread code broke.
    func test_onlyAnObjectiveCSourceLoadsModulesAndNeedsTheSDK() throws {
        _ = try makeTool().process(input: try makeInput(sourcePath: "src/bridge.mm.p", cxxStandard: "c++17",
                                                        otherSettings: ["modules": "true", "objectiveCARC": "true"]))

        XCTAssertTrue(executor.lastArguments.contains("-fobjc-arc"), "\(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("-fmodules"), "\(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("-isysroot"), "\(executor.lastArguments)")

        _ = try makeTool().process(input: try makeInput(sourcePath: "src/thread.c.p",
                                                        otherSettings: ["modules": "true", "objectiveCARC": "true"]))

        XCTAssertFalse(executor.lastArguments.contains("-fobjc-arc"), "\(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("-fmodules"), "\(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("-isysroot"), "\(executor.lastArguments)")
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

    // MARK: - One wire per port

    /// Two configurations on the one port that takes one (B-141): the node publishes an
    /// error naming the port and both wires — a thrown `NodeError` with no state behind it
    /// reaches every output port as its message — and compiles nothing, where it compiled
    /// against whichever the dictionary yielded first.
    func test_twoConfigurationWiresAreAnErrorNamingThemAndNothingIsCompiled() throws {
        let configuration = try XCTUnwrap(try makeInput().inputValues[ClangCompiler.configuration]?.values.first)
        let input = ProcessInput(inputValues: [
            ClangCompiler.configuration: ["machine": configuration, "project": configuration],
            ClangCompiler.input: ["src/hello.c.p": .value(try "int main(){}".intern())],
        ])

        XCTAssertThrowsError(try makeTool().process(input: input)) { error in
            guard let nodeError = error as? NodeError,
                  case .severalWiresOnOneWirePort(let port, let wires) = nodeError else {
                return XCTFail("expected severalWiresOnOneWirePort, got \(error)")
            }
            XCTAssertEqual(port, ClangCompiler.configuration)
            XCTAssertEqual(wires, ["machine", "project"])
            XCTAssertNil(nodeError.publishedState, "published as the error's own message")
        }
        XCTAssertTrue(executor.invocations.isEmpty, "nothing is compiled")
    }

    /// The source port takes one file too: a compiler compiles one translation unit.
    func test_twoSourceWiresAreAnErrorNamingThem() throws {
        var inputValues = try makeInput().inputValues
        inputValues[ClangCompiler.input] = ["src/a.c.p": .value(try "int a;".intern()),
                                            "src/b.c.p": .value(try "int b;".intern())]

        XCTAssertThrowsError(try makeTool().process(input: ProcessInput(inputValues: inputValues))) { error in
            guard case NodeError.severalWiresOnOneWirePort(let port, let wires) = error else {
                return XCTFail("expected severalWiresOnOneWirePort, got \(error)")
            }
            XCTAssertEqual(port, ClangCompiler.input)
            XCTAssertEqual(wires, ["src/a.c.p", "src/b.c.p"])
        }
        XCTAssertTrue(executor.invocations.isEmpty)
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

    /// Assembly compiles like C, as its own language and with no standard (B-55): a
    /// preprocessed `.S`, and a `.s` the formula hands over unpreprocessed.
    func test_assemblesAssemblyWithNoStandard() throws {
        for (sourcePath, language) in [("src/thread.S.p", "assembler-with-cpp"), ("src/thread.s", "assembler")] {
            _ = try makeTool().process(input: try makeInput(sourcePath: sourcePath, cStandard: nil))

            let arguments = executor.lastArguments
            XCTAssertEqual(Array(arguments.prefix(3)), ["-x", language, "-c"], sourcePath)
            XCTAssertFalse(arguments.contains { $0.hasPrefix("-std=") }, "\(sourcePath): \(arguments)")
            XCTAssertTrue(arguments.contains("\(sourcePath).o"), "\(sourcePath): \(arguments)")
        }
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

    /// B-98: the triple on the command line came from a setting, and the failure's remedy
    /// names it under this node's own namespace; the compile belongs to the source, named
    /// without the preprocessor's `.p`.
    func test_aTripleClangRejectsIsReportedWithTheSettingItCameFrom() throws {
        executor.exitCode = 1
        executor.errorOutput = "error: unknown target triple 'nonsense-triple'"

        let output = try makeTool().process(input: try makeInput(target: "nonsense-triple"))

        let document = try XCTUnwrap(output.outputValues[ClangCompiler.output]?.errorDocument,
                                     "a failed compile carries an error: \(String(describing: output.outputValues))")
        XCTAssertEqual(document, ErrorDocument(diagnostic: .tool(text: "error: unknown target triple 'nonsense-triple'", tool: "clang"),
                                               subject: .source(path: "src/hello.c"),
                                               remedy: .setting(keys: ["clang.compiler.target"])))
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
