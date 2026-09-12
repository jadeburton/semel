// ToolRunner.swift
// semel
//
// Infrastructure for executing hermetic build tools (compiler, linker, etc.)
// in an isolated sandbox environment.

import Foundation

// Identifies a specific tool and version
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

/// A tool that can be executed with a set of arguments and input files,
/// producing output files and log messages via a ToolOutput callback object.
public protocol ToolRunner {
    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 output: ToolOutput) throws -> ToolExecuteResult
}

// MARK: - Supporting types

public struct ToolOutput {
    public let logError: (_ error: String) -> Void
    public let logMessage: (_ message: String) -> Void
    public let write: (_ filePath: String, _ data: [UInt8]) -> Void

    // Spelled out because a public struct's memberwise initializer is internal, and a
    // node in another package has to be able to construct one.
    public init(logError: @escaping (_ error: String) -> Void,
                logMessage: @escaping (_ message: String) -> Void,
                write: @escaping (_ filePath: String, _ data: [UInt8]) -> Void) {
        self.logError = logError
        self.logMessage = logMessage
        self.write = write
    }
}

/// A file entry passed to a `ToolRunner`.
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
            guard let bytes = try DataObjectStore.shared.read(hash: hash) else {
                return ""
            }
            return String(decoding: bytes, as: Unicode.UTF8.self)
        }
    }
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

/// A registry that maps ToolDescriptors to their concrete ToolRunner implementations.
public class ToolRunnerRegistry {

    public init() {
    }

    /// Swappable so a test can install a registry holding fake executors without
    /// threading a registry through every node.
    public static var instance = ToolRunnerRegistry()

    private var toolsByDescriptor: [ToolDescriptor: ToolRunner] = [:]

    /// Every tool currently available to build with.  This is what a formula has to name.
    public var registeredDescriptors: [ToolDescriptor] { Array(toolsByDescriptor.keys) }

    public func registerTool(descriptor: ToolDescriptor, toolExecutor: ToolRunner) {
        toolsByDescriptor[descriptor] = toolExecutor
    }

    public func tool(descriptor: ToolDescriptor) throws -> ToolRunner {
        guard let tool = toolsByDescriptor[descriptor] else {
            throw ToolError.noMatchingToolFound(requested: descriptor,
                                                available: registeredDescriptors)
        }
        return tool
    }
}

// ToolRunner supports output streams, however we don't actually use this feature.
// To simplify the call sites we read the streams into simple strings.
public struct SimplifiedToolExecuteResult {
    public let exitCode: Int32
    public let sandboxPathUsed: String
    public let infoOutput: String
    public let errorOutput: String
    public let outputFiles: [String: [UInt8]]
}

extension ToolRunner {
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

extension SimplifiedToolExecuteResult {
    /// The single output file as a wire value, or the tool's error output if it failed.
    ///
    /// Lived on the Clang compiler until the Swift linker turned out to need it too. It is
    /// how any node turns a tool result into something the graph can carry, so it belongs
    /// with the tool types rather than with one toolchain.
    public func asOutputNodeValue() throws -> NodeValue {
        if exitCode == 0 {
            if let outputFile = outputFiles.values.first {
                return .value(try outputFile.intern())
            } else {
                return .noValue(reason: .error(messageDataObjectHash: try "No output file emitted by tool".intern()))
            }
        } else {
            return .noValue(reason: .error(messageDataObjectHash: try errorOutput.intern()))
        }
    }
}
