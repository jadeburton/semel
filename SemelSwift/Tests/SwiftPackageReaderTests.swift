//
//  SwiftPackageReaderTests.swift
//  semel_tests
//
//  This node's output is the dumped manifest, which drives the whole formula and every
//  node downstream of it. Anything it can see that the graph cannot is an input nobody
//  keyed.
//

@testable import SemelSwift
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class SwiftPackageReaderTests: SemelSwiftTestCase {

    private let descriptor = ToolDescriptor(name: "swift",
                                            version: "test-swift",
                                            platform: "macOS",
                                            architecture: "arm64",
                                            recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    private func makeTool() throws -> SwiftPackageReader {
        try SwiftPackageReader(thisNode: NodeRecord(id: 1, kind: SwiftPackageReader.kind))
    }

    private func makeInput() throws -> ProcessInput {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            """
        return ProcessInput(inputValues: [
            SwiftPackageReader.configuration: ["config": .value(try configuration.intern())],
            SwiftPackageReader.packageFile:   ["input:/pkg/Package.swift":
                                                    .value(try "// swift-tools-version:5.9".intern())],
        ])
    }

    // MARK: - Hermeticity

    /// `ToolRunner` deliberately replaces the environment rather than inheriting it —
    /// fixed PATH, and HOME and TMPDIR inside the per-run sandbox — so a manifest that
    /// reads an environment variable (GRDB's own reads SQLITE_ENABLE_PREUPDATE_HOOK) sees
    /// it unset identically on every machine.
    func test_doesNotReachOutsideTheSandboxForItsEnvironment() throws {
        _ = try makeTool().process(input: try makeInput())

        let environment = try XCTUnwrap(executor.invocations.first).environment
        XCTAssertNil(environment["HOME"],
                     "HOME must stay the sandbox the executor chose, got \(environment)")
        XCTAssertNil(environment["TMPDIR"],
                     "TMPDIR must stay the sandbox the executor chose, got \(environment)")
    }

    func test_asksForTheManifestDump() throws {
        _ = try makeTool().process(input: try makeInput())

        XCTAssertEqual(executor.lastArguments, ["package", "dump-package"])
    }

    /// The manifest is placed at the sandbox root regardless of its path in the graph,
    /// because that is where the subcommand looks.
    func test_placesTheManifestAtTheSandboxRoot() throws {
        _ = try makeTool().process(input: try makeInput())

        XCTAssertEqual(try XCTUnwrap(executor.invocations.first).inputFileNames, ["Package.swift"])
    }
}
