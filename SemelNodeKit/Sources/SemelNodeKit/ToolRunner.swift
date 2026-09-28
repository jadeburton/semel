// ToolRunner.swift
// semel
//
// Infrastructure for executing hermetic build tools (compiler, linker, etc.)
// in an isolated sandbox environment.

import Foundation
import SemelDatabaseModels

// Identifies a specific tool and version
public struct ToolDescriptor: Hashable, Codable {
    public let name: String
    public let version: String
    public let platform: String
    public let architecture: String
    /// A fingerprint of the binary behind the four fields above, filled in by
    /// `ToolDiscovery` from the tool it located. Nil in a descriptor a configuration
    /// spells out, which names a tool but cannot know which binary answers to that name
    /// on this machine. It keys the cache — `toolBinaryCacheKeyMaterial` — and never
    /// decides which tool a node runs.
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

    /// What a configuration names when it asks for a tool, and what the registry matches
    /// on. The fingerprint is deliberately outside it: it is discovered rather than
    /// declared, so a config file — hand-written or written by `semel-swift prepare` —
    /// selects a tool by these four fields alone.
    public struct Identity: Hashable {
        public let name: String
        public let version: String
        public let platform: String
        public let architecture: String

        public init(name: String, version: String, platform: String, architecture: String) {
            self.name         = name
            self.version      = version
            self.platform     = platform
            self.architecture = architecture
        }

        /// The identity a node's configuration names, or nil when it does not name all
        /// four — a missing key is reported against the node's namespace by
        /// `RequiredSettings`, which says which one is missing.
        public init?(properties: [String: String]) {
            guard let name         = properties["toolDescriptor.name"],
                  let version      = properties["toolDescriptor.version"],
                  let platform     = properties["toolDescriptor.platform"],
                  let architecture = properties["toolDescriptor.architecture"] else {
                return nil
            }
            self.init(name: name, version: version, platform: platform, architecture: architecture)
        }
    }

    public var identity: Identity {
        .init(name: name, version: version, platform: platform, architecture: architecture)
    }
}

public struct ToolExecuteResult {
    public let exitCode: Int32
    /// The sandbox root as the tool saw it, symlinks resolved (`/var/…` is `/private/var/…`).
    /// For a caller that must undo a path a tool wrote into its output — `swift package
    /// dump-package` prints absolute paths — not for building a command line, which never
    /// names the sandbox (see `ToolSandbox`).
    public let resolvedSandboxPath: String

    public init(exitCode: Int32, resolvedSandboxPath: String) {
        self.exitCode = exitCode
        self.resolvedSandboxPath = resolvedSandboxPath
    }
}

/// A tool that can be executed with a set of arguments and input files,
/// producing output files and log messages via a ToolOutput callback object.
///
/// The contract with the caller is `ToolSandbox`'s: inputs are materialised at their wire
/// keys below a fresh root that is the working directory, every argument is relative to
/// that root, and the root's real name reaches neither the command line nor the outputs.
/// `expectedOutputFolders` are sandbox-relative folders whose every file, at any
/// depth, is reported through `output.writeTreeEntry` — for a tool that decides its
/// own file set. A folder that is not there after the run is an error, like a missing
/// output file.
public protocol ToolRunner {
    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 expectedOutputFolders: [String],
                 output: ToolOutput) throws -> ToolExecuteResult
}

// MARK: - Supporting types

/// What a run hands back. Files arrive as their hashes, interned by the runner from the
/// sandbox (B-116): a tool's output never passes through a node's memory, and a node that
/// wants the bytes of a small one resolves the hash.
public struct ToolOutput {
    public let logError: (_ error: String) -> Void
    public let logMessage: (_ message: String) -> Void
    /// One expected output file, stored, as its hash.
    public let write: (_ filePath: String, _ hash: DataObjectHash) -> Void
    /// One file of an expected output folder: the folder, the path below it, the stored
    /// file's hash and the mode.
    public let writeTreeEntry: (_ folder: String, _ relativePath: String, _ hash: DataObjectHash, _ mode: UInt16) -> Void

    // Spelled out because a public struct's memberwise initializer is internal, and a
    // node in another package has to be able to construct one.
    public init(logError: @escaping (_ error: String) -> Void,
                logMessage: @escaping (_ message: String) -> Void,
                write: @escaping (_ filePath: String, _ hash: DataObjectHash) -> Void,
                writeTreeEntry: @escaping (_ folder: String, _ relativePath: String, _ hash: DataObjectHash, _ mode: UInt16) -> Void = { _, _, _, _ in }) {
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
    /// A node's settings name a tool this machine does not have. `namespace` is the
    /// settings' — `clang.compiler` — and `writer` the command its toolchain registered
    /// for the machine file, when there is one: after a toolchain update it is the machine
    /// file that names a tool no longer installed, and the one thing to do is to write it
    /// again (B-109).
    case noMatchingToolFound(requested: ToolDescriptor, available: [ToolDescriptor],
                             namespace: String, writer: MachineFileWriter?)

    public var description: String {
        switch self {
        case .noMatchingToolFound(let requested, let available, let namespace, let writer):
            let have = available.isEmpty
                ? "no tools are registered"
                : available.map { "\($0.name) \($0.version) (\($0.platform)/\($0.architecture))" }
                           .sorted().joined(separator: ", ")
            let unmatched = "no tool matches \(requested.name) \(requested.version) "
                          + "(\(requested.platform)/\(requested.architecture)); registered: \(have)"
            // The settings arrive merged, so which file named the tool is not known here:
            // the machine file is the likely one, and the project's own file may pin a
            // toolchain on purpose. The writer is named with what makes it replace a file
            // it wrote before.
            let named = "\(namespace).toolDescriptor.* names it"
            guard let writer else {
                return "\(unmatched)\n\(named)."
            }
            let rewrite = writer.rewriteInvocation(folder: MachineFileWriter.folderPlaceholder)
            return "\(unmatched)\n\(named); when that is \(MachineFileWriter.fileName), written before the toolchain "
                 + "changed, '\(rewrite)' rewrites it with the tools installed here."
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

    /// Keyed on the identity, not the whole descriptor: the binary's fingerprint is
    /// discovered and a configuration cannot state it, so matching on it would leave every
    /// node asking for a tool the registry holds and cannot hand over.
    private var toolsByIdentity: [ToolDescriptor.Identity: (descriptor: ToolDescriptor, runner: ToolRunner)] = [:]

    /// A host registers tools while an engine's compute threads look them up, and a
    /// Dictionary read concurrent with a write is undefined, not merely stale.
    private let lock = NSLock()

    /// Every tool currently available to build with.  This is what a formula has to name.
    public var registeredDescriptors: [ToolDescriptor] {
        lock.withLock { toolsByIdentity.values.map(\.descriptor) }
    }

    public func registerTool(descriptor: ToolDescriptor, toolExecutor: ToolRunner) {
        lock.withLock { toolsByIdentity[descriptor.identity] = (descriptor, toolExecutor) }
    }

    /// The registered descriptor for an identity a configuration names — the whole one,
    /// fingerprint included, which is how a node's cache key learns which binary answers
    /// to the version it asked for.
    public func registeredDescriptor(matching identity: ToolDescriptor.Identity) -> ToolDescriptor? {
        lock.withLock { toolsByIdentity[identity]?.descriptor }
    }

    /// The runner for the tool a node's settings name. `namespace` is where those settings
    /// live, so a tool that is not installed is reported with the command that writes the
    /// machine file for that namespace.
    public func tool(descriptor: ToolDescriptor, namespace: String) throws -> ToolRunner {
        guard let tool = lock.withLock({ toolsByIdentity[descriptor.identity]?.runner }) else {
            throw ToolError.noMatchingToolFound(requested: descriptor,
                                                available: registeredDescriptors,
                                                namespace: namespace,
                                                writer:    ToolNamespaceRegistry.entry(forNamespace: namespace)?.machineFileWriter)
        }
        return tool
    }
}

// ToolRunner supports output streams, however we don't actually use this feature.
// To simplify the call sites we read the streams into simple strings.
public struct SimplifiedToolExecuteResult {
    public let exitCode: Int32
    public let resolvedSandboxPath: String
    public let infoOutput: String
    public let errorOutput: String
    /// Each expected output file the tool produced, stored, as its hash.
    public let outputFiles: [String: DataObjectHash]
    /// Every file of each expected output folder, keyed by the folder.
    public let outputTrees: [String: [TreeOutputFile]]
}

/// One file of an output folder, stored: the path below the folder, its hash, its mode.
public struct TreeOutputFile {
    public let relativePath: String
    public let hash: DataObjectHash
    public let mode: UInt16

    public init(relativePath: String, hash: DataObjectHash, mode: UInt16) {
        self.relativePath = relativePath
        self.hash = hash
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
        var outputFiles = [String: DataObjectHash]()
        var outputTrees = [String: [TreeOutputFile]]()

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
                                               write: { filename, hash in
                                                   outputFiles[filename] = hash
                                               },
                                               writeTreeEntry: { folder, relativePath, hash, mode in
                                                   outputTrees[folder, default: []].append(
                                                       TreeOutputFile(relativePath: relativePath, hash: hash, mode: mode))
                                               }))

        return .init(exitCode: result.exitCode,
                     resolvedSandboxPath: result.resolvedSandboxPath,
                     infoOutput: infoOutput,
                     errorOutput: errorOutput,
                     outputFiles: outputFiles,
                     outputTrees: outputTrees)
    }
}

extension SimplifiedToolExecuteResult {
    /// One expected output folder as a tree value: every file already stored by the
    /// runner, the manifest interned, the manifest's hash on the wire. The tool's error
    /// output if it failed. A folder the tool left empty is an empty tree, which is a
    /// value — a catalog with nothing to compile for the platform produces one.
    public func asTreeNodeValue(folder: String,
                                tool: String = "the tool",
                                settings: [SettingArgument] = []) throws -> NodeValue {
        guard exitCode == 0 else {
            let message = failureMessage(tool: tool, settings: settings)
            return .noValue(reason: .error(messageDataObjectHash: try message.intern()))
        }
        let files = outputTrees[folder] ?? []
        let entries = files.map { file in
            TreeManifestEntry(path: file.relativePath, hash: file.hash, mode: file.mode)
        }
        return .value(try TreeManifest(entries: entries).toJSON().intern())
    }

    /// What a failed run says: the exit status, then whatever the tool printed on either
    /// stream. Both, because tools differ in where their diagnostics go — actool under
    /// `--output-format human-readable-text` writes them to stdout — and the status alone
    /// is what is left when a run says nothing at all.
    ///
    /// `settings` are the arguments the node built from settings. Each one the tool's
    /// output complains about adds a closing sentence naming the setting behind the
    /// argument, so a rejected `-target` reads as a key to change rather than as a triple
    /// the reader never typed. A run that complains about none of them carries only the
    /// status and the tool's output.
    public func failureMessage(tool: String = "the tool", settings: [SettingArgument] = []) -> String {
        let printed = [errorOutput, infoOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let headline = "\(tool) exited with status \(exitCode)"
        let message = printed.isEmpty ? headline : "\(headline):\n\(printed)"

        let explained = SettingArgument.sentences(for: settings, matching: printed)
        guard !explained.isEmpty else {
            return message
        }
        return ([message] + explained).joined(separator: "\n")
    }
}

extension SimplifiedToolExecuteResult {
    /// The single output file as a wire value, or what the failed run said.
    ///
    /// Lived on the Clang compiler until the Swift linker turned out to need it too. It is
    /// how any node turns a tool result into something the graph can carry, so it belongs
    /// with the tool types rather than with one toolchain.
    public func asOutputNodeValue(tool: String = "the tool",
                                  settings: [SettingArgument] = []) throws -> NodeValue {
        if exitCode == 0 {
            if let outputFile = outputFiles.values.first {
                return .value(outputFile)
            } else {
                return .noValue(reason: .error(messageDataObjectHash: try "No output file emitted by tool".intern()))
            }
        } else {
            let message = failureMessage(tool: tool, settings: settings)
            return .noValue(reason: .error(messageDataObjectHash: try message.intern()))
        }
    }
}
