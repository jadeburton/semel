//
//  InitFiles.swift
//  SemelVendor
//
//  The two files a tree of Swift packages needs before Semel can build it: a formula
//  naming its roots, and a config stating the toolchain. Semel refuses anything unstated,
//  so the config says everything — what this machine has, for the platform asked for —
//  and the engineer edits it to pin something else.

import Foundation
import SemelClang
import SemelNodeKit
import SemelSwift

/// What the generated config builds for.
public enum Platform: String, CaseIterable {
    case macos = "macos"
    case iosSimulator = "ios-simulator"

    /// The SDK name `xcrun --sdk` and the Swift tools' `sdk` setting take.
    public var sdkName: String {
        switch self {
        case .macos:        return "macosx"
        case .iosSimulator: return "iphonesimulator"
        }
    }

    /// The name a manifest's `platforms` uses for it.
    public var manifestPlatformName: String {
        switch self {
        case .macos:        return "macos"
        case .iosSimulator: return "ios"
        }
    }

    /// The target triple at a deployment version.
    public func target(deploymentVersion: String) -> String {
        switch self {
        case .macos:        return "arm64-apple-macosx\(deploymentVersion)"
        case .iosSimulator: return "arm64-apple-ios\(deploymentVersion)-simulator"
        }
    }
}

/// What the machine has, as `init` reads it. A value type with closures so a test can
/// hand in a machine of its own.
public struct ToolchainFacts {
    public var descriptors: [ToolDescriptor]
    public var namespaces: [ToolNamespace]
    public var sdkPath: (String) -> String?
    public var sdkIdentity: (String) -> String?

    public init(descriptors: [ToolDescriptor], namespaces: [ToolNamespace],
                sdkPath: @escaping (String) -> String?, sdkIdentity: @escaping (String) -> String?) {
        self.descriptors = descriptors
        self.namespaces  = namespaces
        self.sdkPath     = sdkPath
        self.sdkIdentity = sdkIdentity
    }

    /// The real machine: the tools `xcrun` finds, the namespaces the toolchains declare,
    /// and the SDK facts the Swift nodes will check against.
    public static func fromMachine() throws -> ToolchainFacts {
        let registry = ToolRunnerRegistry()
        try DefaultTools.setup(toolExecutorRegistry: registry)
        try SemelSwift.register()
        try SemelClang.register()
        return ToolchainFacts(descriptors: registry.registeredDescriptors,
                              namespaces: ToolNamespaceRegistry.all,
                              sdkPath: SemelSwift.sdkPath(sdk:),
                              sdkIdentity: SemelSwift.sdkIdentity(sdk:))
    }
}

public enum InitFiles {

    public static let formulaFileName = "semel.fmla"
    public static let configFileName  = "semel.config"

    /// One build root above the packages: each root is converted with the formula's folder
    /// as the root, so their common dependencies are vendored once and one config serves
    /// the tree. `rootPaths` are relative to the formula's folder.
    public static func formula(rootPaths: [String]) -> String {
        var lines = [
            "// Written by semel-vendor init. The roots are the packages nothing here depends on",
            "// by path; everything else is reached through them and publishes nothing of its own.",
            "func package(p) = SwiftFormulaConverter(path: p, root: <.>).formula",
        ]
        for path in rootPaths {
            lines.append("include package(p: <\(path)>)")
        }
        return lines.joined(separator: "\n") + "\n"
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

    /// The C standards the clang nodes require stated. SwiftPM's defaults for a target that
    /// declares none — what the vendored C targets were written against.
    static let cStandard   = "gnu11"
    static let cxxStandard = "c++17"

    /// One block per namespace the toolchains declare, in the shape `semel tools` prints,
    /// plus the platform settings each tool needs. A tool installed in several versions
    /// is pinned to the newest; a tool not installed leaves a comment saying so, so the
    /// file still says what is missing.
    public static func config(platform: Platform, deploymentVersion: String, facts: ToolchainFacts) throws -> String {
        guard let sdkIdentity = facts.sdkIdentity(platform.sdkName),
              let sdkPath = facts.sdkPath(platform.sdkName) else {
            throw Vendoring.Failure(description: "no \(platform.sdkName) SDK on this machine (xcrun --sdk \(platform.sdkName))")
        }
        let target = platform.target(deploymentVersion: deploymentVersion)

        var blocks: [String] = [
            """
            // Written by semel-vendor init for --platform \(platform.rawValue): the tools and SDK
            // this machine has, and the deployment version the packages declare. Edit to pin
            // another toolchain; `semel tools` lists what is installed.
            """,
        ]
        for entry in facts.namespaces.sorted(by: { $0.namespace < $1.namespace }) {
            let descriptors = facts.descriptors
                .filter { $0.name == entry.toolName }
                .sorted { ($0.version, $0.platform, $0.architecture) < ($1.version, $1.platform, $1.architecture) }
            guard let descriptor = descriptors.last else {
                blocks.append("// \(entry.namespace): no \(entry.toolName) is installed on this machine")
                continue
            }

            var lines = [
                "\(entry.namespace).toolDescriptor.name=\(descriptor.name)",
                "\(entry.namespace).toolDescriptor.version=\(descriptor.version)",
                "\(entry.namespace).toolDescriptor.platform=\(descriptor.platform)",
                "\(entry.namespace).toolDescriptor.architecture=\(descriptor.architecture)",
            ]
            for (key, value) in platformSettings(toolName: entry.toolName, sdkName: platform.sdkName,
                                                 sdkIdentity: sdkIdentity, sdkPath: sdkPath, target: target) {
                lines.append("\(entry.namespace).\(key)=\(value)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The settings a tool's nodes read besides the descriptor, by tool. The Swift
    /// compiler and linker take the SDK by name and check its identity; clang takes it as
    /// a path and needs the C standards stated. The package reader declares nothing.
    private static func platformSettings(toolName: String, sdkName: String, sdkIdentity: String,
                                         sdkPath: String, target: String) -> [(String, String)] {
        switch toolName {
        case "swiftc":
            return [("sdk", sdkName), ("sdkVersion", sdkIdentity), ("target", target)]
        case "clang":
            return [("sdkPath", sdkPath), ("target", target), ("cStandard", cStandard), ("cxxStandard", cxxStandard)]
        default:
            return []
        }
    }
}
