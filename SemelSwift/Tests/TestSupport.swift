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
        ToolRunnerRegistry.instance = ToolRunnerRegistry()

        // FolderManifest and TreeManifest are decoded by the compiler and linker nodes, and
        // TypeRegistry resolves them through the same process-global registry production uses.
        try TypeRegistry.register(types: [FolderManifest.self, FolderSubtreeManifest.self, TreeManifest.self,
                                          ErrorDocument.self])
        try SemelSwift.register()
    }

    private static func temporaryStoreRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-swift-tests", isDirectory: true)
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
        /// The mode each input that states one is laid with, by its path.
        let inputFileModes: [String: UInt16]
        let expectedOutputFileNames: [String]
        let expectedOutputFolders: [String]
    }

    private(set) var invocations: [Invocation] = []

    /// Files the fake tool "produces", keyed by the output file name the caller expects.
    var producedFiles: [String: [UInt8]] = [:]
    /// Trees the fake tool "produces": folder -> relative path -> bytes.
    var producedTrees: [String: [String: [UInt8]]] = [:]
    var exitCode: Int32 = 0
    /// What the fake tool writes to its error stream, for a test about what a node makes
    /// of a tool's own diagnostics.
    var errorOutput: String = ""

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
                                 inputFileModes: Dictionary(uniqueKeysWithValues: inputFiles.compactMap { file in
                                     file.mode.map { (file.filePath, $0) }
                                 }),
                                 expectedOutputFileNames: expectedOutputFileNames,
                                 expectedOutputFolders: expectedOutputFolders))

        if !errorOutput.isEmpty {
            output.logError(errorOutput)
        }

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

extension Dictionary where Key == String, Value == GraphSpecNode {
    /// The trees as the spec text they render to, for assertions written against text.
    var rendered: [String: String] { mapValues { $0.asString(omitOutputPort: false) } }
}

extension NodeValue {
    /// The document an error value names, read back; nil for a value or another reason.
    var errorDocument: ErrorDocument? {
        guard case .noValue(.error(let hash)) = self else {
            return nil
        }
        return ErrorDocument.read(documentHash: hash)
    }
}
