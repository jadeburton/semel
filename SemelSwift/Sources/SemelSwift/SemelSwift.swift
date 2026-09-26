// SemelSwift.swift
// SemelSwift
//
// What this package contributes, and how a host installs it.
//
// The engine has no idea these types exist. A composition root — the CLI, or a test —
// calls `register()` and from then on the graph can build Swift packages.

import SemelNodeKit

public enum SemelSwift {

    /// Installs this toolchain: its node types, the tools they run and the config
    /// namespaces they read.
    ///
    /// Idempotent, because a host may call it more than once and every test calls it again.
    public static func register() throws {
        try TypeRegistry.register(types: [
            SwiftCompiler.self,
            SwiftLinker.self,
            SwiftPackageReader.self,
            SwiftFormulaConverter.self,
        ])
        // A Package.swift is not discovered as a project of its own. A formula names the
        // package it builds — `include SwiftFormulaConverter(path: <.>).formula` — and the
        // converter wires its own reader from that path. Nothing is registered for it.

        // How `swiftc` and `swift` are found on this machine and versioned. Declared here,
        // located when the engine starts.
        SwiftToolDiscovery.finders.forEach(ToolDiscovery.register)

        // What `tools` prints under each namespace. The compiler and linker check the
        // declared SDK against the machine, so the default SDK's name and the machine's
        // identity for it are printed with them, as a pair to paste; another SDK
        // (`iphonesimulator`) is a choice, so its identity is not guessed at here. The
        // package reader declares no SDK.
        let sdk: () -> [String: String] = {
            resolveSDKVersion(sdk: defaultSDKName).map { ["sdk": defaultSDKName, "sdkVersion": $0] } ?? [:]
        }
        ToolNamespaceRegistry.register(.init(namespace: SwiftCompilerConfiguration.settingNamespace,
                                             toolName: "swiftc", machineSettings: sdk))
        ToolNamespaceRegistry.register(.init(namespace: SwiftLinkerConfiguration.settingNamespace,
                                             toolName: "swiftc", machineSettings: sdk))
        ToolNamespaceRegistry.register(.init(namespace: SwiftPackageReaderConfiguration.settingNamespace,
                                             toolName: "swift"))

        // `include 'swift'`: a target outside a package, from a folder of sources (B-108).
        FormulaIncludeProviders.register(includeProvider)
    }

    // MARK: - What a converted package reads

    /// The config namespaces the formula `SwiftFormulaConverter` emits selects from. For
    /// `semel-swift prepare`, which writes a config block for each and no other.
    public static var converterConfigNamespaces: [String] {
        SwiftFormulaConverter.configNamespaces
    }

    /// The namespaces the converter's formula for a tree selects from: the Swift ones, and
    /// the clang ones only when a target is compiled through clang (B-110).
    public static func converterConfigNamespaces(forCFamilyTargets hasCFamilyTargets: Bool) -> [String] {
        SwiftFormulaConverter.swiftConfigNamespaces + (hasCFamilyTargets ? SwiftFormulaConverter.clangConfigNamespaces : [])
    }

    /// Whether a target folder holding these file names is one the converter compiles
    /// through clang: C-family sources and no top-level `.swift`, the converter's own rule.
    public static func isCFamilyTargetFolder(holding fileNames: [String]) -> Bool {
        let extensions = Set(fileNames.compactMap { name -> String? in
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
                return nil
            }
            return name[name.index(after: dot)...].lowercased()
        })
        return !extensions.contains("swift")
            && !extensions.isDisjoint(with: SwiftFormulaConverter.ClangTargetInfo.cFamilyExtensions)
    }

    // MARK: - SDK facts

    /// The path of the named SDK on this machine, or nil if xcrun knows no such SDK. For a
    /// tool outside the engine that writes a config — `semel-swift prepare` — so it states
    /// what the nodes here will check against, by the same query.
    public static func sdkPath(sdk: String) -> String? {
        resolveSDKPath(sdk: sdk)
    }

    /// The named SDK's identity as `version (build)`, the form `sdkVersion` takes.
    public static func sdkIdentity(sdk: String) -> String? {
        resolveSDKVersion(sdk: sdk)
    }
}

