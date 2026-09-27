//
//  MachineFile.swift
//  SemelMachineFile
//
//  The machine's half of a configuration (B-109), `semel.machine.config`: the descriptors
//  of the tools installed here and the machine settings each namespace declares — the SDK's
//  path or identity — for a platform. Written outside Semel by a toolchain's own tool
//  (B-119): `semel-swift prepare` for a Swift tree, `semel-clang` for a C one. One writer
//  for both, so the file reads the same whichever tool wrote it. It knows no toolchain: the
//  caller registers the toolchains it serves, and hands in the namespaces to write.

import SemelNodeKit
import SemelProtocol

public enum MachineFile {

    public static let fileName = ToolNamespaceRenderer.machineFileName

    /// The tools the registered toolchains find on this machine, as the server finds them
    /// at launch: each declared finder that locates its tool, under the version it
    /// reports.
    public static func installedDescriptors() throws -> [ToolDescriptor] {
        let registry = ToolRunnerRegistry()
        try ToolDiscovery.registerInstalledTools(into: registry)
        return registry.registeredDescriptors
    }

    /// The file's text: for each namespace, alphabetically, the descriptors of its tool
    /// and its machine settings for `platform`. A tool installed in several versions is
    /// pinned to the newest, and a tool not installed leaves a comment saying so — both the
    /// renderer's to decide.
    public static func text(writtenBy writer: String, platform: Platform,
                            descriptors: [ToolDescriptor], namespaces: [ToolNamespace]) -> String {
        let records = namespaces
            .sorted { $0.namespace < $1.namespace }
            .map { entry -> ToolNamespaceRecord in
                let machineSettings = entry.machineSettings(platform)
                let matching = descriptors
                    .filter { $0.name == entry.toolName }
                    .sorted { ($0.version, $0.platform, $0.architecture) < ($1.version, $1.platform, $1.architecture) }
                    .map { descriptor in
                        ToolDescriptorRecord(name:            descriptor.name,
                                             version:         descriptor.version,
                                             platform:        descriptor.platform,
                                             architecture:    descriptor.architecture,
                                             machineSettings: machineSettings)
                    }
                return ToolNamespaceRecord(namespace: entry.namespace, toolName: entry.toolName,
                                           descriptors: matching, selected: true)
            }
        return ToolNamespaceRenderer.machineFile(writtenBy: writer, platformName: platform.rawValue, namespaces: records)
    }
}
