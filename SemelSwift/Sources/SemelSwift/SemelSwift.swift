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
        // converter wires its own reader from that path. What is registered for it is only
        // the include that would build it, so one nothing names is reported (B-10).
        ProjectDiscovery.register(includable: SwiftPackageIncludePlugin())

        // How `swiftc` and `swift` are found on this machine and versioned. Declared here,
        // located when the engine starts.
        SwiftToolDiscovery.finders.forEach(ToolDiscovery.register)

        // What `tools` prints and `semel-swift prepare` writes under each namespace (B-119).
        // The compiler and linker check the declared SDK against the machine, so the SDK's
        // name and the machine's identity for it are the two machine settings they
        // declare, for whichever platform is asked. The package reader declares no SDK.
        let sdk: (Platform) -> [String: String] = { platform in
            resolveSDKVersion(sdk: platform.sdkName).map { ["sdk": platform.sdkName, "sdkVersion": $0] } ?? [:]
        }
        // Prepare rewrites its own namespaces on every run, so it takes no flag to rewrite them.
        let writer = MachineFileWriter(command: "semel-swift prepare")
        ToolNamespaceRegistry.register(.init(namespace: SwiftCompilerConfiguration.settingNamespace,
                                             toolName: "swiftc",
                                             machineSettingKeys: ["sdk", "sdkVersion"], machineSettings: sdk,
                                             machineFileWriter: writer))
        ToolNamespaceRegistry.register(.init(namespace: SwiftLinkerConfiguration.settingNamespace,
                                             toolName: "swiftc",
                                             machineSettingKeys: ["sdk", "sdkVersion"], machineSettings: sdk,
                                             machineFileWriter: writer))
        ToolNamespaceRegistry.register(.init(namespace: SwiftPackageReaderConfiguration.settingNamespace,
                                             toolName: "swift", machineFileWriter: writer))

        // `include 'swift'`: a target outside a package, from a folder of sources (B-108).
        FormulaIncludeProviders.register(includeProvider)
    }

    // MARK: - What a converted package reads

    /// The namespaces the converter's formula for a tree selects from: the Swift ones, and
    /// the clang ones only when a target is compiled through clang (B-110).
    public static func converterConfigNamespaces(forCFamilyTargets hasCFamilyTargets: Bool) -> [String] {
        SwiftFormulaConverter.swiftConfigNamespaces + (hasCFamilyTargets ? SwiftFormulaConverter.clangConfigNamespaces : [])
    }

    /// Whether a target folder holding these files — every one at any depth, as paths
    /// relative to it — is one the converter compiles through clang: C-family sources and
    /// no `.swift` within the scope the manifest's `sources:` and `exclude:` draw (empty
    /// `sources` for the whole folder), the converter's own rule (B-55). The scope is what
    /// keeps a target at its package's root — PLCrashReporter's — from counting the
    /// package's own `Package.swift` and its tests' Swift (B-134).
    public static func isCFamilyTargetFolder(holding relativePaths: [String],
                                             sources: [String] = [],
                                             exclude: [String] = []) -> Bool {
        let scopes     = sources.map(PackageClangTarget.normalized)
        let exclusions = exclude.map(PackageClangTarget.normalized)
        let inScope = relativePaths.filter { path in
            (scopes.isEmpty || scopes.contains { PackageResources.isAtOrUnder(path, $0) })
                && !exclusions.contains { PackageResources.isAtOrUnder(path, $0) }
        }
        let extensions = Set(inScope.compactMap { path -> String? in
            let name = path.split(separator: "/").last.map(String.init) ?? path
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
                return nil
            }
            return name[name.index(after: dot)...].lowercased()
        })
        return !extensions.contains("swift")
            && !extensions.isDisjoint(with: PackageClangTarget.cFamilyExtensions)
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

