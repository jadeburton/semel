//
//  ToolNamespaceRegistry.swift
//  SemelNodeKit
//
//  Which tool each config namespace names. A config file says
//  `swift.compiler.toolDescriptor.name=swiftc`, so the fact is the user's to state — but
//  every node type of a given kind names the same tool, and a listing that prints what is
//  installed under the prefix a config file needs has to know which prefix that is. Each
//  toolchain package declares its namespaces here when it registers its node types.

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
    /// `semel-clang <folder>`, `semel-swift prepare <folder>` — named by the report of a
    /// missing machine setting. The toolchain supplies it, so the core names no tool (B-119).
    public let machineFileCommand: String?

    public init(namespace: String, toolName: String,
                machineSettingKeys: Set<String> = [],
                machineSettings: @escaping (Platform) -> [String: String] = { _ in [:] },
                machineFileCommand: String? = nil) {
        self.namespace          = namespace
        self.toolName           = toolName
        self.machineSettingKeys = machineSettingKeys
        self.machineSettings    = machineSettings
        self.machineFileCommand = machineFileCommand
    }
}

public enum ToolNamespaceRegistry {

    private static var byNamespace: [String: ToolNamespace] = [:]

    /// Idempotent per namespace, because every toolchain's `register()` is.
    public static func register(_ entry: ToolNamespace) {
        byNamespace[entry.namespace] = entry
    }

    /// The entry for one namespace, or nil when no plugin declared it.
    public static func entry(forNamespace namespace: String) -> ToolNamespace? {
        byNamespace[namespace]
    }

    /// Every declared namespace, alphabetical — the registry is a dictionary, and order in
    /// anything printed has to be imposed.
    public static var all: [ToolNamespace] {
        byNamespace.values.sorted { $0.namespace < $1.namespace }
    }
}
