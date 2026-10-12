//
//  SemelApple.swift
//  SemelApple
//
//  The Apple platform tools as nodes: what an app bundle needs beyond compiled code. A
//  host that wants them calls `register()`; the engine itself knows nothing of bundles.

import Foundation
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
            XCFrameworkSliceSelector.self,
            IBToolCompiler.self,
            CodeSigner.self,
            CoreDataModelCompiler.self,
        ])

        // How actool, ibtool, xcstringstool, codesign and momc are found on this machine and versioned.
        // Declared here, located when the engine starts.
        AppleToolDiscovery.finders.forEach(ToolDiscovery.register)

        // What `tools` prints under each namespace, and the machine file `semel-swift
        // prepare` writes for an app (B-119). The plist builder runs no tool. Prepare
        // rewrites its own namespaces on every run, so it takes no flag to rewrite them.
        // ibtool is told the platform's SDK, a fact about the machine for a platform
        // (B-109), which prepare writes as it writes the clang tools' `sdkPath` — with the
        // fingerprint of the tree beside it, so a changed SDK wakes the compiles (B-47).
        let prepare = MachineFileWriter(command: "semel-swift prepare")
        // The asset catalog compiler is told which assetutil checks its canonical Assets.car
        // (B-89), a fact about the machine as the SDK is.
        //
        // Every tool here works through the system's own frameworks, so each namespace is
        // told the system's build as well (`HostOperatingSystem`), the machine file's half
        // of a fact each node also folds into its key (B-153).
        // actool and ibtool compile for iOS through the simulator runtime's frameworks, so
        // for such a platform they are told the runtimes installed (`SimulatorRuntimes`).
        let system   = HostOperatingSystem.buildMachineSettingKey
        let runtimes = SimulatorRuntimes.machineSettingKey
        func runtimeSettings(_ platform: Platform) -> [String: String] {
            SimulatorRuntimes.family(ofPlatformName: platform.sdkName).flatMap(SimulatorRuntimes.provider).map { [runtimes: $0] } ?? [:]
        }
        ToolNamespaceRegistry.register(.init(namespace: AssetCatalogCompilerConfiguration.settingNamespace,
                                             toolName: "actool",
                                             machineSettingKeys: AssetCatalogCompilerConfiguration.machineSettingKeys.union([system, runtimes]),
                                             machineSettings: { platform in
                                                 HostOperatingSystem.machineSettings
                                                     .merging(runtimeSettings(platform)) { _, runtime in runtime }
                                                     .merging(AppleToolDiscovery.locate("assetutil").map { ["assetutilPath": $0] } ?? [:]) { _, located in located }
                                             },
                                             machineFileWriter: prepare))
        ToolNamespaceRegistry.register(.init(namespace: StringCatalogCompilerConfiguration.settingNamespace,
                                             toolName: "xcstringstool",
                                             machineSettingKeys: [system],
                                             machineSettings: { _ in HostOperatingSystem.machineSettings },
                                             machineFileWriter: prepare))
        // momc is told the SDK as ibtool is, by the same machine settings.
        func registerReadingTheSDK(namespace: String, toolName: String, readsRuntimes: Bool) {
            let keys: Set<String> = [sdkPathSettingKey, sdkFingerprintMachineSettingKey, system]
            ToolNamespaceRegistry.register(.init(namespace: namespace,
                                                 toolName: toolName,
                                                 machineSettingKeys: readsRuntimes ? keys.union([runtimes]) : keys,
                                                 machineSettings: { platform in
                                                     var settings = HostOperatingSystem.machineSettings
                                                     if readsRuntimes {
                                                         settings.merge(runtimeSettings(platform)) { _, runtime in runtime }
                                                     }
                                                     guard let path = sdkPath(forPlatform: platform) else {
                                                         return settings
                                                     }
                                                     settings[sdkPathSettingKey] = path
                                                     settings[sdkFingerprintMachineSettingKey] = sdkFingerprint(ofSDKAtPath: path)
                                                     return settings
                                                 },
                                                 machineFileWriter: prepare))
        }
        registerReadingTheSDK(namespace: IBToolCompilerConfiguration.settingNamespace, toolName: "ibtool", readsRuntimes: true)
        registerReadingTheSDK(namespace: CoreDataModelCompilerConfiguration.settingNamespace, toolName: "momc", readsRuntimes: false)
        // codesign is told which codesign_allocate makes room for a signature: the
        // toolchain's, a fact about the machine as the SDK is.
        ToolNamespaceRegistry.register(.init(namespace: CodeSignerConfiguration.settingNamespace,
                                             toolName: "codesign",
                                             machineSettingKeys: CodeSignerConfiguration.machineSettingKeys.union([system]),
                                             machineSettings: { _ in
                                                 HostOperatingSystem.machineSettings.merging(
                                                     AppleToolDiscovery.locate("codesign_allocate").map { ["codesignAllocatePath": $0] } ?? [:]
                                                 ) { _, located in located }
                                             },
                                             machineFileWriter: prepare))

        // `include 'apple'`: an app bundle's resources and Info.plist (B-108).
        FormulaIncludeProviders.register(includeProvider)
    }

    /// Where the platform's SDK is on this machine, as `xcrun` answers, or nil when it has
    /// none. Asked when `tools` or `prepare` asks, not at registration.
    static func sdkPath(forPlatform platform: Platform) -> String? {
        guard let answer = MachineQuery.output(of: "/usr/bin/xcrun", ["--sdk", platform.sdkName, "--show-sdk-path"]) else {
            return nil
        }
        let path = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
