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

struct FileNameAndContent {
    let filePath: String
    let content: [UInt8]
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
    /// In the future this would discover tools from the filesystem or a container,
    /// but for now clang is hardcoded as the sole example.
    static func setup(toolExecutorRegistry: ToolExecutorRegistry) throws {
        try toolExecutorRegistry.registerTool(
            descriptor: .init(name: "clang",
                              version: "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                              platform: "macOS",
                              architecture: "arm64",
                              recursiveHash: nil),
            toolExecutor: LocalFileSystemTool(localPath: "/usr/bin/clang"))
    }
}

// MARK: - Local file system tool

/// Runs a tool that lives in the local filesystem (e.g. /usr/bin/clang) inside a
/// temporary sandbox directory so that the tool cannot accidentally read files
/// that were not explicitly passed in as inputs.
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

        // Ensure the sandbox is always cleaned up, even if we throw partway through.
        defer {
            try? fileManager.removeItem(atPath: sandboxPath)
        }

        // print("Executing tool in sandbox path: \(sandboxPath)")

        // 2. Write all input files into the sandbox, creating intermediate directories as needed.
        for inputFile in inputFiles {
            let inputFileURL = Foundation.URL(fileURLWithPath: sandboxPath)
                .appendingPathComponent(inputFile.filePath)
            let containingDirectory = inputFileURL.deletingLastPathComponent().path

            do {
                if !fileManager.fileExists(atPath: containingDirectory) {
                    try fileManager.createDirectory(atPath: containingDirectory,
                                                    withIntermediateDirectories: true)
                }
                try Foundation.Data(inputFile.content).write(to: inputFileURL)
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

        // Merge the caller-supplied environment on top of a minimal base.
        // We intentionally do NOT inherit the host's full environment to maintain hermeticity.
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

        do {
            try process.run()
        } catch {
            throw ToolExecutionError.processLaunchFailed(underlying: error)
        }

        // 4. Wait for the process to finish and collect stdout/stderr.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let exitCode = process.terminationStatus

        // 5. Forward stdout and stderr to ToolOutput.
        if let stdoutString = String(data: stdoutData, encoding: .utf8), !stdoutString.isEmpty {
            output.logMessage(stdoutString)
        }
        if let stderrString = String(data: stderrData, encoding: .utf8), !stderrString.isEmpty {
            output.logError(stderrString)
        }

        // 6. Read back each expected output file and forward it via ToolOutput.
        //    Missing files are logged as errors so the caller gets maximum information.
        for expectedOutputFileName in expectedOutputFileNames {
            let outputFileURL = Foundation.URL(fileURLWithPath: sandboxPath)
                .appendingPathComponent(expectedOutputFileName)
            if let outputFileData = fileManager.contents(atPath: outputFileURL.path) {
                output.write(expectedOutputFileName, [UInt8](outputFileData))
            } else {
                output.logError("Expected output file not found: \(expectedOutputFileName)")
            }
        }

        // 7. Notify the caller that the tool has terminated.
        return exitCode

        // The defer block above cleans up the sandbox directory.
    }
}
