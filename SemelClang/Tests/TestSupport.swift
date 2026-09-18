//
//  TestSupport.swift
//  SemelClangTests
//
//  The engine's SemelCoreTestCase cannot be used here — SemelSwift deliberately cannot
//  see the engine — so this is the equivalent isolation for a package that only needs the
//  node-authoring API.
//
//  It is markedly smaller than the engine's: no database, no BuildEngine, no graph. That
//  it *can* be this small is the evidence that the split landed where it was supposed to.
//

@testable import SemelClang
import Foundation
import SemelNodeKit
import XCTest

/// Base class for every test here: swaps the process-globals a node can reach.
class SemelClangTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()

        DataObjectStore.shared        = DataObjectStore(storeRoot: Self.temporaryStoreRoot())
        ToolRunnerRegistry.instance = ToolRunnerRegistry()

        // FolderManifest is decoded by the compiler node, and TypeRegistry resolves it
        // through the same process-global registry production uses.
        try TypeRegistry.register(types: [FolderManifest.self])
        try SemelClang.register()
    }

    private static func temporaryStoreRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-clang-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

/// A `ToolRunner` that runs nothing, recording what it was asked to do so a test can
/// assert on the command line a node built.
///
/// Duplicated from the engine's test target rather than shared: a testing-support module
/// for SemelNodeKit would be the tidier answer once a second toolchain package wants one.
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
            output.write(name, producedFiles[name] ?? [])
        }
        for folder in expectedOutputFolders {
            for (relativePath, data) in (producedTrees[folder] ?? [:]).sorted(by: { $0.key < $1.key }) {
                output.writeTreeEntry(folder, relativePath, data, FileMetadata.defaultMode)
            }
        }

        return ToolExecuteResult(exitCode: exitCode, resolvedSandboxPath: "/tmp/recording-tool-sandbox")
    }
}
