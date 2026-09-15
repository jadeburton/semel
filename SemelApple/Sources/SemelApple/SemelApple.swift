//
//  SemelApple.swift
//  SemelApple
//
//  The Apple platform tools as nodes: what an app bundle needs beyond compiled code. A
//  host that wants them calls `register()`; the engine itself knows nothing of bundles.

import SemelNodeKit

public enum SemelApple {

    /// Installs this toolchain: its node types and the config namespaces they read.
    ///
    /// Idempotent, because a host may call it more than once and every test calls it again.
    public static func register() throws {
        try TypeRegistry.register(types: [
            AssetCatalogCompiler.self,
            StringCatalogCompiler.self,
            InfoPlistBuilder.self,
            XcodeProjectConverter.self,
        ])

        // What `tools` prints under each namespace. The plist builder runs no tool.
        ToolNamespaceRegistry.register(.init(namespace: AssetCatalogCompilerConfiguration.settingNamespace,
                                             toolName: "actool"))
        ToolNamespaceRegistry.register(.init(namespace: StringCatalogCompilerConfiguration.settingNamespace,
                                             toolName: "xcstringstool"))
    }
}
