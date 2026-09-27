//
//  ClangLinkerTests.swift
//  semel_tests
//

@testable import SemelClang
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class ClangLinkerTests: SemelClangTestCase {

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

    private func makeTool() throws -> ClangLinker {
        try ClangLinker(thisNode: NodeRecord(id: 1, kind: ClangLinker.kind))
    }

    private func makeInput(objectFiles: [String],
                           libraries: [String] = [],
                           extraConfiguration: [String: String] = [:]) throws -> ProcessInput {
        var properties = [
            "toolDescriptor.name": descriptor.name,
            "toolDescriptor.version": descriptor.version,
            "toolDescriptor.platform": descriptor.platform,
            "toolDescriptor.architecture": descriptor.architecture,
            "target": "arm64-apple-macos14.0",
        ]
        properties.merge(extraConfiguration) { _, new in new }
        let configuration = properties.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")

        var objects: [String: NodeValue] = [:]
        for path in objectFiles { objects[path] = .value(try "object bytes for \(path)".intern()) }

        var libraryValues: [String: NodeValue] = [:]
        for path in libraries { libraryValues[path] = .value(try "library bytes for \(path)".intern()) }

        return ProcessInput(inputValues: [
            ClangLinker.configuration: ["configuration": .value(try configuration.intern())],
            ClangLinker.input: objects,
            ClangLinker.libraries: libraryValues,
        ])
    }

    // MARK: - Command line

    func test_linksObjectFilesIntoADylibForTheTargetArchitecture() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        let arguments = executor.lastArguments
        XCTAssertEqual(Array(arguments.prefix(2)), ["-target", "arm64-apple-macos14.0"])
        XCTAssertTrue(arguments.contains("-lSystem"))
        XCTAssertTrue(arguments.contains("-nostdlib"))
        XCTAssertEqual(Array(arguments.suffix(2)), ["-o", "output.dylib"])
    }

    func test_targetComesFromConfigurationWhenSupplied() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                    extraConfiguration: ["target": "x86_64-apple-macos13.0"]))

        XCTAssertTrue(executor.lastArguments.contains("x86_64-apple-macos13.0"))
        XCTAssertFalse(executor.lastArguments.contains("arm64-apple-macos14.0"))
    }

    func test_dynamicLibraryFlagIsPassedOnlyWhenConfigured() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))
        XCTAssertFalse(executor.lastArguments.contains("-dynamiclib"))

        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                    extraConfiguration: ["dynamicLibrary": "true"]))
        XCTAssertTrue(executor.lastArguments.contains("-dynamiclib"))
    }

    /// `clang.linker.arguments`: the project's extra flags, comma-joined, after what the
    /// node builds — and once, so a `-framework` stated once is passed once.
    func test_extraArgumentsFromTheConfigurationEndTheCommandLineOnce() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                    extraConfiguration: ["arguments": "-framework,Foundation"]))

        let arguments = executor.lastArguments
        XCTAssertEqual(Array(arguments.suffix(4)), ["-o", "output.dylib", "-framework", "Foundation"])
        XCTAssertEqual(arguments.filter { $0 == "-framework" }.count, 1, "got \(arguments)")
    }

    /// The linker's debug map names each object by path. `-oso_prefix .` makes that the
    /// sandbox-relative path, so a binary linked in one sandbox matches one linked in another.
    func test_prefixesTheDebugMapWithTheWorkingDirectory() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        let arguments = executor.lastArguments
        let index = try XCTUnwrap(arguments.firstIndex(of: "-oso_prefix"), "\(arguments)")
        XCTAssertEqual(Array(arguments[(index - 1)...(index + 2)]), ["-Xlinker", "-oso_prefix", "-Xlinker", "."])
        XCTAssertLessThan(index, try XCTUnwrap(arguments.firstIndex(of: "a.o")), "before the objects")
    }

    // MARK: - The C++ runtime

    /// libc++ is linked when any object came from C++ source, judged by suffix at every
    /// stage — a `.C` object counts, and so does Objective-C++ — or when the configuration
    /// declares a C++ standard for the link (B-48: `cxxStandard`, the same key the compiler
    /// reads; the old `std` is not honoured).
    func test_linksTheCPlusPlusRuntimeForCPlusPlusObjectsOrADeclaredCPlusPlusStandard() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.c.p.o"]))
        XCTAssertFalse(executor.lastArguments.contains("-lc++"), "got \(executor.lastArguments)")

        for cxxObject in ["a.cpp.p.o", "a.C.p.o", "a.mm.p.o"] {
            _ = try makeTool().process(input: try makeInput(objectFiles: ["a.c.p.o", cxxObject]))
            XCTAssertTrue(executor.lastArguments.contains("-lc++"), "\(cxxObject): got \(executor.lastArguments)")
        }

        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.c.p.o"],
                                                    extraConfiguration: ["cxxStandard": "c++20"]))
        XCTAssertTrue(executor.lastArguments.contains("-lc++"), "got \(executor.lastArguments)")

        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.c.p.o"],
                                                    extraConfiguration: ["std": "c++20"]))
        XCTAssertFalse(executor.lastArguments.contains("-lc++"), "the old key is gone, got \(executor.lastArguments)")
    }

    // A build must produce the same command line from the same inputs. Object files and
    // libraries arrive in a dictionary, whose iteration order is not stable, so they have
    // to be put into a defined order before they reach the command line.
    func test_objectFilesAreOrderedDeterministically() throws {
        let objectFiles = ["zebra.o", "alpha.o", "middle.o", "beta.o", "yankee.o"]

        _ = try makeTool().process(input: try makeInput(objectFiles: objectFiles))

        let listed = executor.lastArguments.filter { $0.hasSuffix(".o") }
        XCTAssertEqual(listed, objectFiles.sorted(),
                       "object files must reach the linker in a defined order")
    }

    func test_librariesAreOrderedDeterministically() throws {
        let libraries = ["libz.a", "libapple.a", "libmiddle.a"]

        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"], libraries: libraries))

        let listed = executor.lastArguments.filter { $0.hasSuffix(".a") }
        XCTAssertEqual(listed, libraries.sorted(),
                       "libraries must reach the linker in a defined order")
    }

    func test_everyObjectAndLibraryIsPassedToTheToolAsAnInputFile() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o", "b.o"],
                                                    libraries: ["libc.a"]))

        XCTAssertEqual(executor.invocations.first?.inputFileNames.sorted(),
                       ["a.o", "b.o", "libc.a"])
    }

    // MARK: - Result mapping

    func test_successfulLinkPublishesTheLinkedBinary() throws {
        executor.producedFiles = ["output.dylib": Array("LINKED".utf8)]

        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        let value = try XCTUnwrap(output.outputValues[ClangLinker.output])
        XCTAssertEqual(try value.expectValue().resolveAsString(), "LINKED")
    }

    func test_failedLinkPublishesNoBinary() throws {
        executor.exitCode = 1

        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        let value = try XCTUnwrap(output.outputValues[ClangLinker.output])
        XCTAssertTrue(value.isNoValue, "a failed link must not publish a binary")
    }

    // MARK: - What a rejected argument says (B-98)

    private func failureMessage(_ output: ProcessOutput) throws -> String {
        guard case .noValue(.error(let hash)) = output.outputValues[ClangLinker.output] else {
            XCTFail("a failed link carries an error: \(String(describing: output.outputValues))")
            return ""
        }
        return try hash.resolveAsString()
    }

    func test_aTripleClangRejectsIsReportedWithTheSettingItCameFrom() throws {
        executor.exitCode = 1
        executor.errorOutput = "error: unknown target triple 'nonsense-triple'"

        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                                 extraConfiguration: ["target": "nonsense-triple"]))

        let message = try failureMessage(output)
        XCTAssertTrue(message.contains("`clang.linker.target` is `nonsense-triple`"), "got \(message)")
        XCTAssertTrue(message.contains("clang -print-target-triple"), "got \(message)")
    }

    /// The SDK path reaches the linker as a search path, and the search path is what the
    /// linker echoes: the one setting whose own value identifies the complaint about it.
    ///
    /// A missing search path does not fail the link on its own — the driver hands `ld` a
    /// `-syslibroot` for the machine's default SDK, so `-lSystem` resolves from there and
    /// the run only warns. So the sentence appears where a reader needs it: on a link that
    /// failed for another reason while the declared SDK was quietly doing nothing. This is
    /// what `clang -target arm64-apple-macos14.0 -L . -L /no/such/sdk/usr/lib -lSystem
    /// -nostdlib -Xlinker -oso_prefix -Xlinker . und.o -o output.dylib` prints — this
    /// node's own argument shape, against an object with an undefined symbol.
    func test_aSearchPathTheLinkerCannotFindIsReportedWithTheSDKSetting() throws {
        executor.exitCode = 1
        executor.errorOutput = """
            ld: warning: search path '/no/such/sdk/usr/lib' not found
            Undefined symbols for architecture arm64:
              "_missing", referenced from:
                  _main in und.o
            ld: symbol(s) not found for architecture arm64
            clang: error: linker command failed with exit code 1 (use -v to see invocation)
            """

        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                                 extraConfiguration: ["sdkPath": "/no/such/sdk"]))

        let message = try failureMessage(output)
        XCTAssertTrue(message.contains("`clang.linker.sdkPath` is `/no/such/sdk`"), "got \(message)")
        XCTAssertTrue(message.contains("xcrun --sdk <name> --show-sdk-path"), "got \(message)")
    }

    /// An error in what was linked is not about the command line. The same failure as
    /// above with the same declared SDK, minus the warning that the SDK's search path was
    /// missing: without the linker's own word about it, the SDK is not named.
    func test_anErrorInTheObjectsNamesNoSetting() throws {
        executor.exitCode = 1
        executor.errorOutput = """
            Undefined symbols for architecture arm64:
              "_missing", referenced from:
                  _main in a.o
            ld: symbol(s) not found for architecture arm64
            clang: error: linker command failed with exit code 1 (use -v to see invocation)
            """

        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"],
                                                                 extraConfiguration: ["sdkPath": "/no/such/sdk"]))

        XCTAssertEqual(try failureMessage(output), """
            clang exited with status 1:
            Undefined symbols for architecture arm64:
              "_missing", referenced from:
                  _main in a.o
            ld: symbol(s) not found for architecture arm64
            clang: error: linker command failed with exit code 1 (use -v to see invocation)
            """)
    }
}
