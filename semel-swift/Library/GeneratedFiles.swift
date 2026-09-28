//
//  GeneratedFiles.swift
//  SemelSwiftTool
//
//  The files a tree of Swift packages needs before Semel can build it: a formula naming
//  its roots, and its configuration as two files (B-109) — the machine's half, the tools
//  and SDK this machine has, which nobody edits or commits; and the project's half, what
//  the manifests declare and the choices prepare starts the project off with, which is
//  checked in and edited from there. Semel refuses anything unstated, so between them the
//  two say everything.

import Foundation
import SemelApple
import SemelClang
import SemelMachineFile
import SemelNodeKit
import SemelProtocol
import SemelSwift
/// What the machine has, as `prepare` reads it. A value type with closures so a test can
/// hand in a machine of its own.
public struct ToolchainFacts {
    public var descriptors: [ToolDescriptor]
    /// The namespaces the toolchains declare, each answering its own machine settings.
    public var namespaces: [ToolNamespace]
    /// The SDK's identity, for the deployment version a tree that declares none falls
    /// back to; what the tools need to know about the SDK, the namespaces answer.
    public var sdkIdentity: (String) -> String?

    public init(descriptors: [ToolDescriptor], namespaces: [ToolNamespace], sdkIdentity: @escaping (String) -> String?) {
        self.descriptors = descriptors
        self.namespaces  = namespaces
        self.sdkIdentity = sdkIdentity
    }

    /// The real machine: the tools the toolchains find on it and the namespaces they
    /// declare.
    public static func fromMachine() throws -> ToolchainFacts {
        try SemelSwift.register()
        try SemelClang.register()
        try SemelApple.register()
        return ToolchainFacts(descriptors: try MachineFile.installedDescriptors(),
                              namespaces: ToolNamespaceRegistry.all,
                              sdkIdentity: SemelSwift.sdkIdentity(sdk:))
    }
}

public enum GeneratedFiles {

    public static let formulaFileName       = "semel.fmla"
    public static let configFileName        = "semel.config"
    public static let machineConfigFileName = MachineFile.fileName

    /// One build root above the packages: each root is converted with the formula's folder
    /// as the root, so their common dependencies are vendored once and one config serves
    /// the tree. `rootPaths` are relative to the formula's folder.
    public static func formula(rootPaths: [String]) -> String {
        var lines = [
            "// Written by semel-swift prepare. The roots are the packages nothing here depends on",
            "// by path; everything else is reached through them and publishes nothing of its own.",
            "func package(p) = SwiftFormulaConverter(path: p, root: <.>).formula",
        ]
        for path in rootPaths {
            lines.append("include package(p: <\(path)>)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A project as the one root: the converter reads it, walks its targets' folders and
    /// brings every package it references, all under this folder as the build root.
    public static func formula(project: String, platform: Platform) -> String {
        """
        // Written by semel-swift prepare. The project is the root: its converter brings every
        // package it references and builds the application and the extensions it embeds.
        include XcodeProjectConverter(path: <\(project)>, root: <.>, configuration: 'Debug', sdk: '\(platform.sdkName)').formula

        """
    }

    /// The config namespaces the formula for a tree of packages selects from: what
    /// `SwiftFormulaConverter` emits reads — the clang ones only when a target is a
    /// C-family one, since a block nothing reads is reported as unused on every build.
    public static func packageTreeNamespaces(forCFamilyTargets hasCFamilyTargets: Bool) -> [String] {
        SemelSwift.converterConfigNamespaces(forCFamilyTargets: hasCFamilyTargets)
    }

    /// Whether any of a tree's targets is compiled through clang, read from the target
    /// folders on disk by the converter's own rule.
    public static func hasCFamilyTargets(in summaries: [PackageSummary]) -> Bool {
        summaries.flatMap(\.targetFolders).contains { folder in
            SemelSwift.isCFamilyTargetFolder(holding: (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        }
    }

    /// The config namespaces the formula for a project selects from: what the project
    /// converter emits for its own targets reads, and what the package formulas it
    /// includes read.
    public static var projectNamespaces: [String] {
        XcodeProjectConverter.configNamespaces + SemelSwift.converterConfigNamespaces
    }

    /// The highest deployment version the packages declare for the platform, or nil when
    /// none does. Highest, because a root that declares 18.0 cannot be built for 17.0
    /// whatever its dependencies allow.
    public static func deploymentVersion(for platform: Platform, in summaries: [PackageSummary]) -> String? {
        summaries
            .compactMap { $0.platforms[platform.manifestPlatformName] }
            .max { compare($0, $1) == .orderedAscending }
    }

    /// `26.5 (23F81a)` -> `26.5`: the SDK's own version, the deployment version when no
    /// manifest states one — everything the SDK has is then allowed.
    public static func version(fromSDKIdentity identity: String) -> String {
        identity.components(separatedBy: " ").first ?? identity
    }

    private static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }

    /// The C standards prepare starts a project off with. SwiftPM's defaults for a target
    /// that declares none — what the vendored C targets were written against — written
    /// into the project file as the choice they are, not as clang's defaults.
    static let cStandard   = "gnu11"
    static let cxxStandard = "c++17"

    /// The machine's half: the tool descriptors and the machine settings each namespace
    /// declares — the SDK's path or identity — for the namespaces the formula selects
    /// from, and no other, because the engine reports a key no filter claims as unused on
    /// every build. Written by the one writer `semel-clang` uses too (B-119).
    public static func machineConfig(platform: Platform, facts: ToolchainFacts, namespaces: [String]) -> String {
        let wanted = Set(namespaces)
        return MachineFile.text(writtenBy: "semel-swift prepare", platform: platform, descriptors: facts.descriptors,
                                namespaces: facts.namespaces.filter { wanted.contains($0.namespace) })
    }

    /// The project's half: what prepare derives from the manifests and the platform — the
    /// target triple at the deployment version, and what actool needs to know about the
    /// platform — plus, for the clang tools, a language standard to start from, under a
    /// comment naming it the choice it is. A namespace with nothing of the project's to
    /// say — the package reader, xcstringstool — has no block. Written once; the project
    /// edits and checks it in from there.
    public static func projectConfig(platform: Platform, deploymentVersion: String, facts: ToolchainFacts,
                                     namespaces: [String]) -> String {
        let target = platform.target(deploymentVersion: deploymentVersion)
        let wanted = Set(namespaces)

        var blocks: [String] = [
            """
            // Written by semel-swift prepare for --platform \(platform.rawValue): the project's choices —
            // the target at the deployment version the manifests declare, and for the clang
            // tools a language standard to start from. Yours to edit and check in. The machine's
            // tools and SDK are in \(machineConfigFileName) beside this file, which prepare
            // rewrites.
            """,
        ]
        for entry in facts.namespaces.sorted(by: { $0.namespace < $1.namespace }) where wanted.contains(entry.namespace) {
            let lines = projectSettings(namespace: entry.namespace, toolName: entry.toolName, platform: platform,
                                        target: target, deploymentVersion: deploymentVersion)
            guard !lines.isEmpty else {
                continue
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The project file's lines for one namespace, by tool. The Swift compiler and linker
    /// and the clang tools take the target triple; clang also wants the language standards
    /// stated, which are the project's to choose; actool takes the platform by name with
    /// the deployment version and devices that decide what it compiles. A comment is a
    /// line of its own: everything after a value's `=` is the value.
    private static func projectSettings(namespace: String, toolName: String, platform: Platform,
                                        target: String, deploymentVersion: String) -> [String] {
        switch toolName {
        case "swiftc":
            return ["\(namespace).target=\(target)"]
        case "clang":
            return ["\(namespace).target=\(target)",
                    "// prepare's starting point, not clang's default: the project's choice of standard",
                    "\(namespace).cStandard=\(cStandard)",
                    "\(namespace).cxxStandard=\(cxxStandard)"]
        case "actool":
            return ["\(namespace).platform=\(platform.sdkName)",
                    "\(namespace).minimumDeploymentTarget=\(deploymentVersion)",
                    "\(namespace).targetDevices=\(platform.targetDevices)"]
        default:
            return []
        }
    }
}
