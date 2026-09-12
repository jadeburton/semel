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
    /// Settings besides `toolDescriptor.*` whose value is a fact about this machine and so
    /// worth printing beside the tool — the SDK identity for the Swift tools. Evaluated
    /// when listed, not when registered, and sorted by key when printed.
    public let machineSettings: () -> [String: String]

    public init(namespace: String, toolName: String, machineSettings: @escaping () -> [String: String] = { [:] }) {
        self.namespace       = namespace
        self.toolName        = toolName
        self.machineSettings = machineSettings
    }
}

public enum ToolNamespaceRegistry {

    private static var byNamespace: [String: ToolNamespace] = [:]

    /// Idempotent per namespace, because every toolchain's `register()` is.
    public static func register(_ entry: ToolNamespace) {
        byNamespace[entry.namespace] = entry
    }

    /// Every declared namespace, alphabetical — the registry is a dictionary, and order in
    /// anything printed has to be imposed.
    public static var all: [ToolNamespace] {
        byNamespace.values.sorted { $0.namespace < $1.namespace }
    }
}
