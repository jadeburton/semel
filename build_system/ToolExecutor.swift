// ToolExecutor.swift
// build_system
//
// Infrastructure for executing hermetic build tools (compiler, linker, etc.)
// in an isolated sandbox environment.

import Foundation

// MARK: - Protocol

struct ToolDescriptor: Hashable, Codable {
    let name: String
    let version: String
    let platform: String
    let architecture: String
    let recursiveHash: String?
}

/// A build tool that can be executed with a set of arguments and input files,
/// producing output files and log messages via a ToolOutput callback object.
protocol ToolExecutor {
    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 output: ToolOutput) throws -> Int32
}

// MARK: - Supporting types

struct ToolOutput {
    let logError: (_ error: String) -> Void
    let logMessage: (_ message: String) -> Void
    let write: (_ filePath: String, _ data: [UInt8]) -> Void
}

/// A file entry passed to a `ToolExecutor`.
///
/// The content is never held in memory here — it must already be stored in
/// `DataObjectStore` before the tool is invoked.  `LocalFileSystemTool`
/// projects the file into the sandbox via an APFS copy-on-write clone using
/// the SHA-256 `hash` as the lookup key.
struct FileNameAndContent {
    let filePath: String
    /// SHA-256 hex digest that identifies the content in `DataObjectStore`.
    let hash: String
}

extension FileNameAndContent {
    /// Reads the content from `DataObjectStore` and decodes it as UTF-8.
    var contentAsString: String {
        get throws {
            guard let bytes = DataObjectStore.shared.read(hash: hash) else { return "" }
            return String(decoding: bytes, as: Unicode.UTF8.self)
        }
    }
}

enum ToolExecutionError: Error {
    case toolNotFound(path: String)
    case toolNotExecutable(path: String)
    case failedToCreateSandbox(underlying: Error)
    case failedToWriteInputFile(fileName: String, underlying: Error)
    case failedToReadOutputFile(fileName: String)
    case processLaunchFailed(underlying: Error)
}

enum ToolError: Error {
    case noMatchingToolFound
}

// MARK: - Registry

/// A registry that maps ToolDescriptors to their concrete ToolExecutor implementations.
class ToolExecutorRegistry {
    static let instance = ToolExecutorRegistry()

    private var toolsByDescriptor: [ToolDescriptor: ToolExecutor] = [:]

    func registerTool(descriptor: ToolDescriptor, toolExecutor: ToolExecutor) {
        toolsByDescriptor[descriptor] = toolExecutor
    }

    func tool(descriptor: ToolDescriptor) throws -> ToolExecutor {
        guard let tool = toolsByDescriptor[descriptor] else {
            throw ToolError.noMatchingToolFound
        }
        return tool
    }
}

// MARK: - Default tools

class DefaultTools {
    /// Registers all known tools with the given registry.
    static func setup(toolExecutorRegistry: ToolExecutorRegistry) throws {
        try toolExecutorRegistry.registerTool(
            descriptor: .init(name: "clang",
                              version: "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                              platform: "macOS",
                              architecture: "arm64",
                              recursiveHash: ""),
            toolExecutor: LocalFileSystemTool(localPath: "/usr/bin/clang"))
    }
}

// MARK: - Local file system tool

/// Runs a tool that lives in the local filesystem (e.g. /usr/bin/clang) inside a
/// temporary sandbox directory so that the tool cannot accidentally read files
/// that were not explicitly passed in as inputs.
///
/// Input files are populated via `DataObjectStore.project(hash:to:)`, which uses
/// an APFS copy-on-write clone (essentially free) when available.
/// All input bytes must already be stored in `DataObjectStore` before calling
/// `execute` — `FileNameAndContent` carries only the path and the hash.
class LocalFileSystemTool: ToolExecutor {
    private let localPath: String

    init(localPath: String) throws {
        self.localPath = localPath

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: localPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ToolExecutionError.toolNotFound(path: localPath)
        }
        guard fileManager.isExecutableFile(atPath: localPath) else {
            throw ToolExecutionError.toolNotExecutable(path: localPath)
        }
    }

    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 output: ToolOutput) throws -> Int32 {

        let fileManager = FileManager.default

        // 1. Create a temporary sandbox directory.
        let sandboxPath: String
        do {
            let sandboxURL = try fileManager.url(for: .itemReplacementDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: fileManager.temporaryDirectory,
                                                 create: true)
            sandboxPath = sandboxURL.path
        } catch {
            throw ToolExecutionError.failedToCreateSandbox(underlying: error)
        }

        defer { try? fileManager.removeItem(atPath: sandboxPath) }

        // 2. Populate input files in the sandbox via DataObjectStore (APFS clone).
        for inputFile in inputFiles {

            let destinationURL = Foundation.URL(fileURLWithPath: sandboxPath).appendingPathComponent(inputFile.filePath)
            let containingDirectory = destinationURL.deletingLastPathComponent().path

            do {
                if !fileManager.fileExists(atPath: containingDirectory) {
                    try fileManager.createDirectory(atPath: containingDirectory,
                                                    withIntermediateDirectories: true)
                }

                // Throws if not found.
                try DataObjectStore.shared.project(hash: inputFile.hash, to: destinationURL)

            } catch {
                throw ToolExecutionError.failedToWriteInputFile(fileName: inputFile.filePath,
                                                               underlying: error)
            }
        }

        // 3. Configure and launch the process.
        let process = Foundation.Process()
        process.executableURL = Foundation.URL(fileURLWithPath: localPath)
        process.arguments = arguments
        process.currentDirectoryURL = Foundation.URL(fileURLWithPath: sandboxPath)

        var processEnvironment: [String: String] = [
            "PATH":   "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME":   sandboxPath,
            "TMPDIR": sandboxPath,
        ]

        for (key, value) in environment {
            processEnvironment[key] = value
        }

        process.environment = processEnvironment

        let stdoutPipe = Foundation.Pipe()
        let stderrPipe = Foundation.Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        do { try process.run() } catch {
            throw ToolExecutionError.processLaunchFailed(underlying: error)
        }

        // 4. Drain stdout and stderr on background threads WHILE the process runs.
        //    Reading after waitUntilExit() risks deadlock if the tool writes more
        //    than the OS pipe buffer (~64 KB) before the process exits.
        var stdoutData = Foundation.Data()
        var stderrData = Foundation.Data()
        let ioGroup = DispatchGroup()

        ioGroup.enter()

        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }

        ioGroup.enter()

        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            ioGroup.leave()
        }

        process.waitUntilExit()
        ioGroup.wait()

        let exitCode = process.terminationStatus

        // 5. Forward stdout and stderr to ToolOutput.
        if let text = String(data: stdoutData, encoding: .utf8), !text.isEmpty {
            output.logMessage(text)
        }

        if let text = String(data: stderrData, encoding: .utf8), !text.isEmpty {
            output.logError(text)
        }

        // 6. Read back expected output files and forward via ToolOutput.
        for expectedOutputFileName in expectedOutputFileNames {
            let outputFileURL = Foundation.URL(fileURLWithPath: sandboxPath)
                .appendingPathComponent(expectedOutputFileName)
            if let data = fileManager.contents(atPath: outputFileURL.path) {
                output.write(expectedOutputFileName, [UInt8](data))
            } else {
                output.logError("Expected output file not found: \(expectedOutputFileName)")
            }
        }

        return exitCode
    }
}
