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

    /// The command, outside Semel, that writes this toolchain's machine settings (B-119).
    /// It leaves a file that already holds its namespaces as it is, unless told `--force`.
    public static let machineFileWriter = MachineFileWriter(command: "semel-clang", rewriteFlags: ["--force"])

    /// Where the platform's SDK is on this machine, as `xcrun` answers, or nil when it has
    /// none. Asked when `tools` asks, not at registration.
    static func sdkPath(forPlatform platform: Platform) -> String? {
        guard let answer = MachineQuery.output(of: "/usr/bin/xcrun", ["--sdk", platform.sdkName, "--show-sdk-path"]) else {
            return nil
        }
        let path = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Installs this toolchain's node types, the tool they run and the config namespaces
    /// they read. Idempotent, so a host may call it more than once and every test calls it
    /// again.
    public static func register() throws {
        try TypeRegistry.register(types: [
            ClangCompiler.self,
            ClangLinker.self,
            ClangPreprocessor.self,
            ClangIncludeFinder.self,
            ClangArchiver.self,
        ])

        // How clang and libtool are found on this machine and versioned. Declared here,
        // located when the engine starts.
        ToolDiscovery.register(ClangToolDiscovery.finder)
        ToolDiscovery.register(ClangToolDiscovery.libtoolFinder)

        // What `tools` prints and `semel-clang` writes under each namespace (B-119). The
        // compiler, preprocessor and linker run the one clang binary and the archiver runs
        // libtool; the include finder runs no tool. The preprocessor and the linker read
        // the SDK at `sdkPath`, a fact about the machine for a platform, so they declare it
        // as one (B-109); so does the compiler, which takes preprocessed text but, with
        // `modules`, loads the modules that text imports from the SDK (B-77). The archiver
        // takes objects and reads no SDK.
        ToolNamespaceRegistry.register(.init(namespace: ClangArchiverConfiguration.settingNamespace, toolName: "libtool",
                                             machineFileWriter: machineFileWriter))
        for namespace in [ClangPreprocessorConfiguration.settingNamespace,
                          ClangCompilerConfiguration.settingNamespace,
                          ClangLinkerConfiguration.settingNamespace] {
            ToolNamespaceRegistry.register(.init(namespace: namespace, toolName: "clang",
                                                 machineSettingKeys: ["sdkPath"],
                                                 machineSettings: { platform in
                                                     sdkPath(forPlatform: platform).map { ["sdkPath": $0] } ?? [:]
                                                 },
                                                 machineFileWriter: machineFileWriter))
        }

        // `include 'clang'`: executables, dylibs and archives from a folder of sources (B-108).
        FormulaIncludeProviders.register(includeProvider)
    }
}
