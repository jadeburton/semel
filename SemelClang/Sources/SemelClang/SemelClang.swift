// SemelClang.swift
// SemelClang
//
// What this package contributes, and how a host installs it.
//
// Unlike SemelSwift there is no project kind here: a C or C++ project is described by a
// `.fmla` file, which the engine recognises itself because a formula names no toolchain.
// So this package contributes node types, the tool they run and their namespaces.

import SemelNodeKit

public enum SemelClang {

    /// Installs this toolchain's node types, the tool they run and the config namespaces
    /// they read. Idempotent, so a host may call it more than once and every test calls it
    /// again.
    public static func register() throws {
        try TypeRegistry.register(types: [
            ClangCompiler.self,
            ClangLinker.self,
            ClangPreprocessor.self,
            ClangIncludeFinder.self,
        ])

        // How clang is found on this machine and versioned. Declared here, located when
        // the engine starts.
        ToolDiscovery.register(ClangToolDiscovery.finder)

        // What `tools` prints under each namespace. All three run the one clang binary;
        // the include finder runs no tool.
        for namespace in [ClangCompilerConfiguration.settingNamespace,
                          ClangLinkerConfiguration.settingNamespace,
                          ClangPreprocessorConfiguration.settingNamespace] {
            ToolNamespaceRegistry.register(.init(namespace: namespace, toolName: "clang"))
        }
    }
}
