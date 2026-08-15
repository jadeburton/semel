// ToolExecutor.swift
// build_system
//
// Infrastructure for executing hermetic build tools (compiler, linker, etc.)
// in an isolated sandbox environment.

import Foundation
import SemelNodeKit

// MARK: - Protocol

public struct ToolDescriptor: Hashable, Codable {
    public let name: String
    public let version: String
    public let platform: String
    public let architecture: String
    public let recursiveHash: String?

    public init(name: String,
         version: String,
         platform: String,
         architecture: String,
         recursiveHash: String?) {

        self.name = name
        self.version = version
        self.platform = platform
        self.architecture = architecture
        self.recursiveHash = recursiveHash
    }

    public init(properties: [String: String]) {
        name = properties["toolDescriptor.name"] ?? ""
        version = properties["toolDescriptor.version"] ?? ""
        platform = properties["toolDescriptor.platform"] ?? ""
        architecture = properties["toolDescriptor.architecture"] ?? ""
        recursiveHash = properties["toolDescriptor.recursiveHash"]
    }
}

public struct SimplifiedToolExecuteResult {
    public let exitCode: Int32
    // This is needed in cases where a tool writes the temporary path into an output file. We need to undo that.
    public let sandboxPathUsed: String
    public let infoOutput: String
    public let errorOutput: String
    public let outputFiles: [String: [UInt8]]
}

public struct ToolExecuteResult {
    public let exitCode: Int32
    // This is needed in cases where a tool writes the temporary path into an output file. We need to undo that.
    public let sandboxPathUsed: String

    public init(exitCode: Int32, sandboxPathUsed: String) {
        self.exitCode = exitCode
        self.sandboxPathUsed = sandboxPathUsed
    }
}

/// A build tool that can be executed with a set of arguments and input files,
/// producing output files and log messages via a ToolOutput callback object.
public protocol ToolExecutor {
    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 output: ToolOutput) throws -> ToolExecuteResult
}

extension ToolExecutor {
    // Simplified version of execute that does not stream the outputs
    public func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String]) throws -> SimplifiedToolExecuteResult {

        var infoOutput = ""
        var errorOutput = ""
        var outputFiles = [String: [UInt8]]()

        let result = try execute(arguments: arguments,
                                   environment: environment,
                                   inputFiles: inputFiles,
                                   expectedOutputFileNames: expectedOutputFileNames,
                                   output: .init(logError: { error in
                                                     errorOutput += error
                                                     errorOutput += "\n"
                                                 },
                                                 logMessage: { message in
                                                     infoOutput += message
                                                     infoOutput += "\n"
                                                 },
                                                 write: { filename, data in
                                                     if outputFiles[filename] == nil {
                                                         outputFiles[filename] = data
                                                     } else {
                                                         outputFiles[filename] = outputFiles[filename]! + data
                                                     }
                                                 }))

        return .init(exitCode: result.exitCode,
                     sandboxPathUsed: result.sandboxPathUsed,
                     infoOutput: infoOutput,
                     errorOutput: errorOutput,
                     outputFiles: outputFiles)
    }
}

// MARK: - Supporting types

public struct ToolOutput {
    public let logError: (_ error: String) -> Void
    public let logMessage: (_ message: String) -> Void
    public let write: (_ filePath: String, _ data: [UInt8]) -> Void
    // ISSUE: the JSON file has abs paths to the temp directory. we need to remove these but we need the ToolExecutor to tell us what dir it used

    // Spelled out because a public struct's memberwise initializer is internal, and a
    // node function in another package has to be able to construct one.
    public init(logError: @escaping (_ error: String) -> Void,
                logMessage: @escaping (_ message: String) -> Void,
                write: @escaping (_ filePath: String, _ data: [UInt8]) -> Void) {
        self.logError = logError
        self.logMessage = logMessage
        self.write = write
    }
}

/// A file entry passed to a `ToolExecutor`.
///
/// The content is never held in memory here — it must already be stored in
/// `DataObjectStore` before the tool is invoked.  `LocalFileSystemTool`
/// projects the file into the sandbox via an APFS copy-on-write clone using
/// the SHA-256 `hash` as the lookup key.
public struct FileNameAndContent {
    public let filePath: String
    /// SHA-256 hex digest that identifies the content in `DataObjectStore`.
    public let hash: String

    public init(filePath: String, hash: String) {
        self.filePath = filePath
        self.hash = hash
    }
}

extension FileNameAndContent {
    /// Reads the content from `DataObjectStore` and decodes it as UTF-8.
    public var contentAsString: String {
        get throws {
            guard let bytes = try DataObjectStore.shared.read(hash: hash) else { return "" }
            return String(decoding: bytes, as: Unicode.UTF8.self)
        }
    }
}

public enum ToolExecutionError: Error {
    case toolNotFound(path: String)
    case toolNotExecutable(path: String)
    case failedToCreateSandbox(underlying: Error)
    case failedToWriteInputFile(fileName: String, underlying: Error)
    case failedToReadOutputFile(fileName: String)
    case processLaunchFailed(underlying: Error)
}

public enum ToolError: Error, CustomStringConvertible {
    case noMatchingToolFound(requested: ToolDescriptor, available: [ToolDescriptor])

    public var description: String {
        switch self {
        case .noMatchingToolFound(let requested, let available):
            let have = available.isEmpty
                ? "no tools are registered"
                : available.map { "\($0.name) \($0.version) (\($0.platform)/\($0.architecture))" }
                           .sorted().joined(separator: ", ")
            return "no tool matches \(requested.name) \(requested.version) "
                 + "(\(requested.platform)/\(requested.architecture)); registered: \(have)"
        }
    }
}

// MARK: - Registry

/// A registry that maps ToolDescriptors to their concrete ToolExecutor implementations.
public class ToolExecutorRegistry {

    public init() {}

    /// Swappable so a test can install a registry holding fake executors without
    /// threading a registry through every node function.
    public static var instance = ToolExecutorRegistry()

    private var toolsByDescriptor: [ToolDescriptor: ToolExecutor] = [:]

    /// Every tool currently available to build with.  This is what a formula has to name.
    public var registeredDescriptors: [ToolDescriptor] { Array(toolsByDescriptor.keys) }

    public func registerTool(descriptor: ToolDescriptor, toolExecutor: ToolExecutor) {
        toolsByDescriptor[descriptor] = toolExecutor
    }

    public func tool(descriptor: ToolDescriptor) throws -> ToolExecutor {
        guard let tool = toolsByDescriptor[descriptor] else {
            throw ToolError.noMatchingToolFound(requested: descriptor,
                                                available: registeredDescriptors)
        }
        return tool
    }
}

// MARK: - Default tools

public class DefaultTools {

    /// The tools this build system knows how to run, by name.  This list is the only
    /// hard-coded part: both the path and the version come from the machine.
    private static let knownToolNames = ["clang", "swiftc", "swift"]

    /// Registers whatever is actually installed.
    ///
    /// Each tool is located with `xcrun --find` and registered under the version it
    /// reports, so a descriptor always describes the binary that will really run.
    ///
    /// Nothing is warned about here.  Installing a newer toolchain is not by itself a
    /// problem, and a node that does not use the changed tool is unaffected — so there is
    /// nothing to say at launch.  A node whose configuration names a version that is no
    /// longer installed fails when it is processed, and `ToolError.noMatchingToolFound`
    /// names both what it asked for and what is available, so the fix is to update that
    /// node's configuration.  Keeping the version in the configuration rather than
    /// following the machine is deliberate: it is what makes a toolchain upgrade
    /// invalidate the cache instead of silently reusing objects built by another compiler.
    public static func setup(toolExecutorRegistry: ToolExecutorRegistry) throws {
        for name in knownToolNames {
            guard let path = Toolchain.find(name),
                  let version = Toolchain.version(ofToolAt: path) else {
                continue
            }

            toolExecutorRegistry.registerTool(
                descriptor: .init(name: name,
                                  version: version,
                                  platform: "macOS",
                                  architecture: "arm64",
                                  recursiveHash: nil),
                toolExecutor: try LocalFileSystemTool(localPath: path))
        }
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
public class LocalFileSystemTool: ToolExecutor {
    private let localPath: String

    public init(localPath: String) throws {
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

    public func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 output: ToolOutput) throws -> ToolExecuteResult {

        let fileManager = FileManager.default

        // 1. Create a temporary sandbox directory.
        let sandboxPath: String
        let canonicalSandboxPath: String
        do {
            let sandboxURL = try fileManager.url(for: .itemReplacementDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: fileManager.temporaryDirectory,
                                                 create: true)
            sandboxPath = sandboxURL.path
            // On macOS, /var is a symlink to /private/var. Tools like SPM call
            // realpath() internally and write /private/var/... in their output
            // even when the process ran in /var/.... Normalise the path here so
            // callers can match against those output paths.
            canonicalSandboxPath = sandboxPath.hasPrefix("/var/") ? "/private" + sandboxPath : sandboxPath
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

        return .init(exitCode: exitCode, sandboxPathUsed: canonicalSandboxPath)
    }
}
