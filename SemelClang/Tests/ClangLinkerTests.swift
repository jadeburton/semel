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
}
