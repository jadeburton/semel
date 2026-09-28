//
//  ToolNamespaceRegistry.swift
//  SemelNodeKit
//
//  Which tool each config namespace names. A config file says
//  `swift.compiler.toolDescriptor.name=swiftc`, so the fact is the user's to state — but
//  every node type of a given kind names the same tool, and a listing that prints what is
//  installed under the prefix a config file needs has to know which prefix that is. Each
//  toolchain package declares its namespaces here when it registers its node types.

import Foundation

/// One config namespace and the tool it names.
public struct ToolNamespace {
    /// `swift.compiler`, `clang.linker`, …
    public let namespace: String
    /// The registered tool name this namespace's nodes run: `swiftc`, `clang`.
    public let toolName: String
    /// The keys, besides `toolDescriptor.*`, whose value is a fact about the machine rather
    /// than the project's choice: the SDK's path or identity. What the toolchain's own tool
    /// writes into `semel.machine.config` and a project never types (B-109). Declared apart
    /// from the values so a report can say which kind a missing key is without asking the
    /// machine.
    public let machineSettingKeys: Set<String>
    /// Those settings' values on this machine, for a platform — the SDK is one per
    /// platform. Evaluated when asked, not when registered, and sorted by key when printed.
    public let machineSettings: (Platform) -> [String: String]
    /// The command, outside Semel, that writes this namespace's machine settings —
    /// `semel-clang`, `semel-swift prepare` — named by the report of a missing machine
    /// setting, of a machine file nobody has written, and of a tool the file names that is
    /// no longer installed. The toolchain supplies it, so the core names no tool (B-119).
    public let machineFileWriter: MachineFileWriter?

    public init(namespace: String, toolName: String,
                machineSettingKeys: Set<String> = [],
                machineSettings: @escaping (Platform) -> [String: String] = { _ in [:] },
                machineFileWriter: MachineFileWriter? = nil) {
        self.namespace          = namespace
        self.toolName           = toolName
        self.machineSettingKeys = machineSettingKeys
        self.machineSettings    = machineSettings
        self.machineFileWriter  = machineFileWriter
    }
}

/// A command outside Semel that writes `semel.machine.config` into a folder: the
/// toolchain's own tool (B-119). Typed rather than a command line with a placeholder in it,
/// so that the engine can name it with the folder a report is about, and a tool's error
/// with what rewrites a file already there, without taking a sentence apart.
public struct MachineFileWriter: Hashable, Comparable {

    /// The file every writer writes, beside the project's `semel.config` (B-109). One name:
    /// `.gitignore`, the writers, the converter's formula, the tutorial and the fixtures.
    public static let fileName = "semel.machine.config"

    /// The command up to the folder it writes into: `semel-clang`, `semel-swift prepare`.
    public let command: String
    /// What the command takes after the folder to replace the blocks it wrote before —
    /// `--force` for a writer that otherwise leaves a file holding its namespaces as it is,
    /// nothing for one that rewrites its own on every run.
    public let rewriteFlags: [String]

    public init(command: String, rewriteFlags: [String] = []) {
        self.command      = command
        self.rewriteFlags = rewriteFlags
    }

    /// `semel-clang hello`: the command run on one folder.
    public func invocation(folder: String) -> String {
        "\(command) \(folder)"
    }

    /// `semel-clang hello --force`: the command that replaces what it wrote there before.
    public func rewriteInvocation(folder: String) -> String {
        ([command, folder] + rewriteFlags).joined(separator: " ")
    }

    /// The command as a person is told it with no folder in hand: `semel-clang <folder>`.
    public static let folderPlaceholder = "<folder>"

    public static func < (lhs: MachineFileWriter, rhs: MachineFileWriter) -> Bool {
        (lhs.command, lhs.rewriteFlags.joined(separator: " ")) < (rhs.command, rhs.rewriteFlags.joined(separator: " "))
    }
}

public enum ToolNamespaceRegistry {

    /// A toolchain registers while an engine's compute threads may be reading, and a
    /// Dictionary read concurrent with a write is undefined, not merely stale.
    private static let lock = NSLock()
    private static var byNamespace: [String: ToolNamespace] = [:]

    /// Idempotent per namespace, because every toolchain's `register()` is.
    public static func register(_ entry: ToolNamespace) {
        lock.withLock { byNamespace[entry.namespace] = entry }
    }

    /// The entry for one namespace, or nil when no plugin declared it.
    public static func entry(forNamespace namespace: String) -> ToolNamespace? {
        lock.withLock { byNamespace[namespace] }
    }

    /// Every declared namespace, alphabetical — the registry is a dictionary, and order in
    /// anything printed has to be imposed.
    public static var all: [ToolNamespace] {
        lock.withLock { byNamespace.values.sorted { $0.namespace < $1.namespace } }
    }
}
