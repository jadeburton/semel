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
    /// `expectedOutputFolders` are sandbox-relative folders whose every file, at any
    /// depth, is reported through `output.writeTreeEntry` — for a tool that decides its
    /// own file set. A folder that is not there after the run is an error, like a missing
    /// output file.
    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 expectedOutputFolders: [String],
                 output: ToolOutput) throws -> ToolExecuteResult
}

// MARK: - Supporting types

public struct ToolOutput {
    public let logError: (_ error: String) -> Void
    public let logMessage: (_ message: String) -> Void
    public let write: (_ filePath: String, _ data: [UInt8]) -> Void
    /// One file of an expected output folder: the folder, the path below it, the bytes
    /// and the mode.
    public let writeTreeEntry: (_ folder: String, _ relativePath: String, _ data: [UInt8], _ mode: UInt16) -> Void

    // Spelled out because a public struct's memberwise initializer is internal, and a
    // node in another package has to be able to construct one.
    public init(logError: @escaping (_ error: String) -> Void,
                logMessage: @escaping (_ message: String) -> Void,
                write: @escaping (_ filePath: String, _ data: [UInt8]) -> Void,
                writeTreeEntry: @escaping (_ folder: String, _ relativePath: String, _ data: [UInt8], _ mode: UInt16) -> Void = { _, _, _, _ in }) {
        self.logError = logError
        self.logMessage = logMessage
        self.write = write
        self.writeTreeEntry = writeTreeEntry
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
    /// Every file of each expected output folder, keyed by the folder.
    public let outputTrees: [String: [TreeFileContent]]
}

/// One collected file of an output folder, before it is interned.
public struct TreeFileContent {
    public let relativePath: String
    public let data: [UInt8]
    public let mode: UInt16

    public init(relativePath: String, data: [UInt8], mode: UInt16) {
        self.relativePath = relativePath
        self.data = data
        self.mode = mode
    }
}

extension ToolRunner {
    // Simplified version of execute that does not stream the outputs
    public func execute(arguments: [String],
                        environment: [String: String],
                        inputFiles: [FileNameAndContent],
                        expectedOutputFileNames: [String],
                        expectedOutputFolders: [String] = []) throws -> SimplifiedToolExecuteResult {

        var infoOutput = ""
        var errorOutput = ""
        var outputFiles = [String: [UInt8]]()
        var outputTrees = [String: [TreeFileContent]]()

        let result = try execute(arguments: arguments,
                                 environment: environment,
                                 inputFiles: inputFiles,
                                 expectedOutputFileNames: expectedOutputFileNames,
                                 expectedOutputFolders: expectedOutputFolders,
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
                                               },
                                               writeTreeEntry: { folder, relativePath, data, mode in
                                                   outputTrees[folder, default: []].append(
                                                       TreeFileContent(relativePath: relativePath, data: data, mode: mode))
                                               }))

        return .init(exitCode: result.exitCode,
                     sandboxPathUsed: result.sandboxPathUsed,
                     infoOutput: infoOutput,
                     errorOutput: errorOutput,
                     outputFiles: outputFiles,
                     outputTrees: outputTrees)
    }
}

extension SimplifiedToolExecuteResult {
    /// One expected output folder as a tree value: every file interned, the manifest
    /// interned, the manifest's hash on the wire. The tool's error output if it failed;
    /// an error naming the folder if the tool succeeded without producing it.
    public func asTreeNodeValue(folder: String) throws -> NodeValue {
        guard exitCode == 0 else {
            return .noValue(reason: .error(messageDataObjectHash: try errorOutput.intern()))
        }
        guard let files = outputTrees[folder] else {
            return .noValue(reason: .error(messageDataObjectHash: try "No output folder \(folder) emitted by tool".intern()))
        }
        let entries = try files.map { file in
            TreeManifestEntry(path: file.relativePath, hash: try file.data.intern(), mode: file.mode)
        }
        return .value(try TreeManifest(entries: entries).toJSON().intern())
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
