//
//  TestSupport.swift
//  SemelSwiftTests
//
//  The engine's SemelCoreTestCase cannot be used here — SemelSwift deliberately cannot
//  see the engine — so this is the equivalent isolation for a package that only needs the
//  node-authoring API.
//
//  It is markedly smaller than the engine's: no database, no BuildEngine, no graph. That
//  it *can* be this small is the evidence that the split landed where it was supposed to.
//

@testable import SemelSwift
import Foundation
import SemelNodeKit
import XCTest

/// Base class for every test here: swaps the process-globals a node can reach.
class SemelSwiftTestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()

        DataObjectStore.shared        = DataObjectStore(storeRoot: Self.temporaryStoreRoot())
        ToolExecutorRegistry.instance = ToolExecutorRegistry()

        // FolderManifest is decoded by the compiler node, and PolyFactory resolves it
        // through the same process-global registry production uses.
        try PolyFactory.register(types: [FolderManifest.self])
        try SemelSwift.register()
    }

    private static func temporaryStoreRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-swift-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

/// A `ToolExecutor` that runs nothing, recording what it was asked to do so a test can
/// assert on the command line a node built.
///
/// Duplicated from the engine's test target rather than shared: a testing-support module
/// for SemelNodeKit would be the tidier answer once a second toolchain package wants one.
final class RecordingToolExecutor: ToolExecutor {

    struct Invocation {
        let arguments: [String]
        let environment: [String: String]
        let inputFileNames: [String]
        let expectedOutputFileNames: [String]
    }

    private(set) var invocations: [Invocation] = []

    /// Files the fake tool "produces", keyed by the output file name the caller expects.
    var producedFiles: [String: [UInt8]] = [:]
    var exitCode: Int32 = 0

    var lastArguments: [String] { invocations.last?.arguments ?? [] }

    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 output: ToolOutput) throws -> ToolExecuteResult {

        invocations.append(.init(arguments: arguments,
                                 environment: environment,
                                 inputFileNames: inputFiles.map(\.filePath),
                                 expectedOutputFileNames: expectedOutputFileNames))

        for name in expectedOutputFileNames {
            output.write(name, producedFiles[name] ?? [])
        }

        return ToolExecuteResult(exitCode: exitCode, sandboxPathUsed: "/tmp/recording-tool-sandbox")
    }
}
