//
//  SemelApple.swift
//  SemelApple
//
//  The Apple platform tools as nodes: what an app bundle needs beyond compiled code. A
//  host that wants them calls `register()`; the engine itself knows nothing of bundles.

import SemelNodeKit

public enum SemelApple {

    /// Installs this toolchain: its node types, the tools they run and the config
    /// namespaces they read.
    ///
    /// Idempotent, because a host may call it more than once and every test calls it again.
    public static func register() throws {
        try TypeRegistry.register(types: [
            AssetCatalogCompiler.self,
            StringCatalogCompiler.self,
            InfoPlistBuilder.self,
            XcodeProjectConverter.self,
        ])

        // How actool and xcstringstool are found on this machine and versioned. Declared
        // here, located when the engine starts.
        AppleToolDiscovery.finders.forEach(ToolDiscovery.register)

        // What `tools` prints under each namespace, and the machine file `semel-swift
        // prepare` writes for an app (B-119). The plist builder runs no tool.
        ToolNamespaceRegistry.register(.init(namespace: AssetCatalogCompilerConfiguration.settingNamespace,
                                             toolName: "actool", machineFileCommand: "semel-swift prepare <folder>"))
        ToolNamespaceRegistry.register(.init(namespace: StringCatalogCompilerConfiguration.settingNamespace,
                                             toolName: "xcstringstool", machineFileCommand: "semel-swift prepare <folder>"))

        // `include 'apple'`: an app bundle's resources and Info.plist (B-108).
        FormulaIncludeProviders.register(includeProvider)
    }
}
