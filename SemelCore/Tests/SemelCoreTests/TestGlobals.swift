//
//  TestGlobals.swift
//  semel_tests
//
//  The build system resolves its object store, symbol table and tool registry through
//  process-globals on purpose: threading them through every `intern()` and every node
//  function would be far more plumbing than it is worth.  The cost of that trade is
//  that a test must be able to swap out what those globals point at before it runs.
//  `TestGlobals.isolate()` is that swap — call it from `setUpWithError`.
//

@testable import SemelCore
import Foundation
import XCTest
import SemelNodeKit

/// Base class for every test in this target: isolates the process-globals before each
/// test so nothing leaks between them and nothing reaches the user's real object store.
/// Subclasses that override `setUpWithError` must call `super.setUpWithError()`.
class SemelCoreTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try TestGlobals.isolate()
    }
}

enum TestGlobals {

    /// Points every process-global the build system relies on at fresh, per-test state:
    /// a private object store in a temp directory, an empty tool registry, and no engine.
    ///
    /// The caller is still responsible for creating its own `DatabaseLayer` — doing so
    /// already resets `DatabaseLayer.shared` and the symbol cache.
    static func isolate() throws {
        DataObjectStore.shared        = DataObjectStore(storeRoot: makeTemporaryStoreRoot())
        ToolRunnerRegistry.instance = ToolRunnerRegistry()
        FormulaIncludeProviders.removeAll()
        // Registered again by `registerTypes` below, the engine's own plugin among them; a
        // test's own project plugins are dropped.
        ProjectDiscovery.removeAll()
        BuildEngine.shared            = nil

        // Formula parsing resolves a node's default output port through the TypeRegistry
        // registry, so a test that skips this would parse against a different rulebook
        // than production — and would pass or fail depending on which test ran first.
        try BuildEngine.registerTypes()

        // The stand-ins these tests use in place of a toolchain node. Registered here for
        // the same reason the engine's own types are: GraphSpecNode.parse resolves a type
        // name through the factory.
        try TypeRegistry.register(types: [SampleTool.self, OtherSampleTool.self, DemandingSampleTool.self,
                                                 UncachedSampleTool.self, LabellingSampleTool.self,
                                                 CompilingSampleTool.self])
    }

    private static func makeTemporaryStoreRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

/// A `ToolRunner` that runs nothing.  It records what it was asked to do so a test can
/// assert on the command line a tool wrapper built, and reports whatever exit code the
/// test asked for.
final class RecordingToolRunner: ToolRunner {

    struct Invocation {
        let arguments: [String]
        let environment: [String: String]
        let inputFileNames: [String]
        let expectedOutputFileNames: [String]
        let expectedOutputFolders: [String]
    }

    private(set) var invocations: [Invocation] = []

    /// Files the fake tool "produces", keyed by the output file name the caller expects.
    var producedFiles: [String: [UInt8]] = [:]
    /// Trees the fake tool "produces": folder -> relative path -> bytes.
    var producedTrees: [String: [String: [UInt8]]] = [:]
    var exitCode: Int32 = 0

    var lastArguments: [String] { invocations.last?.arguments ?? [] }

    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 expectedOutputFolders: [String],
                 output: ToolOutput) throws -> ToolExecuteResult {

        invocations.append(.init(arguments: arguments,
                                 environment: environment,
                                 inputFileNames: inputFiles.map(\.filePath),
                                 expectedOutputFileNames: expectedOutputFileNames,
                                 expectedOutputFolders: expectedOutputFolders))

        for name in expectedOutputFileNames {
            output.write(name, try (producedFiles[name] ?? []).intern())
        }
        for folder in expectedOutputFolders {
            for (relativePath, data) in (producedTrees[folder] ?? [:]).sorted(by: { $0.key < $1.key }) {
                output.writeTreeEntry(folder, relativePath, try data.intern(), FileMetadata.defaultMode)
            }
        }

        return ToolExecuteResult(exitCode: exitCode, resolvedSandboxPath: "/tmp/recording-tool-sandbox")
    }
}
