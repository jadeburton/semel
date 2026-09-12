// SemelSwift.swift
// SemelSwift
//
// What this package contributes, and how a host installs it.
//
// The engine has no idea these types exist. A composition root — the CLI, or a test —
// calls `register()` and from then on the graph can build Swift packages.

import SemelNodeKit

public enum SemelSwift {

    /// Installs this toolchain: its node types and the project kind it recognises.
    ///
    /// Idempotent, because a host may call it more than once and every test calls it again.
    public static func register() throws {
        try TypeRegistry.register(types: [
            SwiftCompiler.self,
            SwiftLinker.self,
            SwiftPackageReader.self,
            SwiftFormulaConverter.self,
        ])
        // A Package.swift is not discovered: a formula names the package it builds
        // (`package <.>`), and this is how the engine turns that folder into a formula.
        ProjectDiscovery.register(packageFormulaProvider: SwiftPackageFormulaProvider())

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
    }
}

// MARK: - Packages named by a formula

/// Turns the folder a formula's `package <folder>` names into the reader-and-converter
/// chain whose output is that package's formula. Only a formula creates a ProjectBuilder,
/// so only the formula's products — which are the master package's, merged in — are
/// published; a dependency package has no builder and no artifacts of its own (B-10).
struct SwiftPackageFormulaProvider: PackageFormulaProvider {
    func formulaSpec(forPackageFolder packageFolder: String) -> String {
        let manifestPath = "\(packageFolder)/Package.swift"

        // The reader shells out to a toolchain, so it needs the same `toolDescriptor` settings
        // every other tool does. This is the first node of every Swift build: wired to an
        // empty Configuration it fails before the manifest is ever read. It selects from the
        // config file beside the package, as every node of the build does.
        let pkgReaderExpr = SwiftFormulaConverter.packageReaderSpec(
            packageFilePath: manifestPath,
            rootPackageFolder: packageFolder)

        return "SwiftFormulaConverter(" +
               "packageFolder: ['\(packageFolder)': Folder(path: '\(packageFolder)').manifest], " +
               "packageJSON: ['\(manifestPath)': \(pkgReaderExpr)]" +
               ").formula"
    }
}
