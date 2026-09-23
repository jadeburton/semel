//
//  TestSupport.swift
//  SemelAppleTests
//
//  The same isolation SemelClang's tests use: a package that only needs the node-authoring
//  API swaps the process-globals a node can reach, and nothing more.
//

@testable import SemelApple
import Foundation
import SemelNodeKit
import XCTest

/// Base class for every test here: swaps the process-globals a node can reach.
class SemelAppleTestCase: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared      = DataObjectStore(storeRoot: Self.temporaryStoreRoot())
        ToolRunnerRegistry.instance = ToolRunnerRegistry()
        // The manifests the nodes decode resolve through the same process-global registry
        // production uses.
        try TypeRegistry.register(types: [FolderManifest.self, TreeManifest.self])
        try SemelApple.register()
    }

    private static func temporaryStoreRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-apple-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    // MARK: - Helpers

    func manifestValue(_ path: String, files: [String] = [], folders: [String] = []) throws -> NodeValue {
        let entries = files.map { FolderManifestEntry(name: $0, isFolder: false, isPinned: true) }
                    + folders.map { FolderManifestEntry(name: $0, isFolder: true, isPinned: true) }
        return .value(try FolderManifest(baseFolderPath: path, entries: entries).toJSON().intern())
    }

    func treeManifest(from value: NodeValue?) throws -> TreeManifest {
        let json = try XCTUnwrap(value).expectValue()
        return try TypeRegistry.decodeAndCast(encodedJSON: try json.resolveAsString())
    }
}

/// A `ToolRunner` that runs nothing, recording what it was asked to do so a test can
/// assert on the command line a node built.
///
/// Duplicated from the engine's test target rather than shared, like the other toolchain
/// packages' copies.
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
    var errorOutput = ""
    var infoOutput = ""

    var lastArguments: [String] { invocations.last?.arguments ?? [] }
    var lastInputFileNames: [String] { invocations.last?.inputFileNames ?? [] }

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

        if !errorOutput.isEmpty {
            output.logError(errorOutput)
        }
        if !infoOutput.isEmpty {
            output.logMessage(infoOutput)
        }
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
