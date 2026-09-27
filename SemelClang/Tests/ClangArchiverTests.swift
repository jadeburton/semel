//
//  ClangArchiverTests.swift
//  SemelClangTests
//
//  The archiver's work is one libtool command line and the bytes it leaves; a recording
//  executor sees both. What matters here is what makes two archives of one set of objects
//  the same bytes: the members in a defined order, and a timestamp libtool is told not to
//  write.
//

@testable import SemelClang
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class ClangArchiverTests: SemelClangTestCase {

    private let descriptor = ToolDescriptor(name: "libtool",
                                            version: "test-libtool",
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

    private func makeTool() throws -> ClangArchiver {
        try ClangArchiver(thisNode: NodeRecord(id: 1, kind: ClangArchiver.kind))
    }

    private func makeInput(objectFiles: [String], toolDescriptor: Bool = true) throws -> ProcessInput {
        var properties: [String: String] = [:]
        if toolDescriptor {
            properties = [
                "toolDescriptor.name": descriptor.name,
                "toolDescriptor.version": descriptor.version,
                "toolDescriptor.platform": descriptor.platform,
                "toolDescriptor.architecture": descriptor.architecture,
            ]
        }
        let configuration = properties.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")

        var objects: [String: NodeValue] = [:]
        for path in objectFiles { objects[path] = .value(try "object bytes for \(path)".intern()) }

        return ProcessInput(inputValues: [
            ClangArchiver.configuration: ["configuration": .value(try configuration.intern())],
            ClangArchiver.input: objects,
        ])
    }

    // MARK: - Command line

    func test_archivesTheObjectFilesWithLibtoolIntoAStaticArchive() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.c.p.o"]))

        XCTAssertEqual(executor.lastArguments, ["-static", "-o", "output.a", "a.c.p.o"])
        XCTAssertEqual(executor.invocations.first?.expectedOutputFileNames, ["output.a"])
    }

    /// The members' order is the archive's bytes, and the objects arrive in a dictionary.
    func test_objectFilesAreOrderedDeterministically() throws {
        let objectFiles = ["zebra.o", "alpha.o", "middle.o", "beta.o", "yankee.o"]

        _ = try makeTool().process(input: try makeInput(objectFiles: objectFiles))

        XCTAssertEqual(executor.lastArguments.filter { $0.hasSuffix(".o") }, objectFiles.sorted())
        XCTAssertEqual(executor.invocations.first?.inputFileNames, objectFiles.sorted())
    }

    /// Without it the `ar` header of every member carries the wall clock, and two cold
    /// builds of the same objects differ.
    func test_libtoolIsToldToWriteNoTimestamps() throws {
        _ = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        XCTAssertEqual(executor.invocations.first?.environment, ["ZERO_AR_DATE": "1"])
    }

    // MARK: - Result mapping

    func test_aSuccessfulArchivePublishesTheArchiveAtTheDefaultMode() throws {
        executor.producedFiles = ["output.a": Array("!<arch>".utf8)]

        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        let archive = try XCTUnwrap(output.outputValues[ClangArchiver.output])
        XCTAssertEqual(try archive.expectValue().resolveAsString(), "!<arch>")
        let metadata = try XCTUnwrap(output.outputValues[FileMetadata.portName]).expectValue().resolveAsString()
        XCTAssertTrue(metadata.contains("\(FileMetadata.defaultMode)"), "an archive is linked, not run: \(metadata)")
    }

    func test_aFailedArchivePublishesNoArchive() throws {
        executor.exitCode = 1

        let output = try makeTool().process(input: try makeInput(objectFiles: ["a.o"]))

        XCTAssertTrue(try XCTUnwrap(output.outputValues[ClangArchiver.output]).isNoValue)
    }

    /// The tool descriptor is the machine's to write; missing, it is reported under this
    /// node's own namespace so the message names the block `semel-clang` writes.
    func test_aMissingToolDescriptorIsReportedUnderTheArchiverNamespace() throws {
        XCTAssertThrowsError(try makeTool().process(input: try makeInput(objectFiles: ["a.o"], toolDescriptor: false))) { error in
            XCTAssertTrue("\(error)".contains("clang.archiver.toolDescriptor.name"), "got \(error)")
        }
    }
}
