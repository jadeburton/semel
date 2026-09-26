//
//  GeneratedFiles.swift
//  SemelSwiftTool
//
//  The two files a tree of Swift packages needs before Semel can build it: a formula
//  naming its roots, and a config stating the toolchain. Semel refuses anything unstated,
//  so the config says everything — what this machine has, for the platform asked for —
//  and the engineer edits it to pin something else.

import Foundation
import SemelApple
import SemelClang
import SemelNodeKit
import SemelSwift
/// What the machine has, as `prepare` reads it. A value type with closures so a test can
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

    /// The real machine: the tools the toolchains find on it, the namespaces they declare,
    /// and the SDK facts the Swift nodes will check against.
    public static func fromMachine() throws -> ToolchainFacts {
        try SemelSwift.register()
        try SemelClang.register()
        try SemelApple.register()
        let registry = ToolRunnerRegistry()
        try ToolDiscovery.registerInstalledTools(into: registry)
        return ToolchainFacts(descriptors: registry.registeredDescriptors,
                              namespaces: ToolNamespaceRegistry.all,
                              sdkPath: SemelSwift.sdkPath(sdk:),
                              sdkIdentity: SemelSwift.sdkIdentity(sdk:))
    }
}

public enum GeneratedFiles {

    public static let formulaFileName = "semel.fmla"
    public static let configFileName  = "semel.config"

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

    /// The namespaces a formula's text selects, from its `prefix: '…'` literals: what a
    /// hand-written formula names in `ConfigFilter(prefix: 'swift.compiler', …)` or through
    /// a func of its own, `settings(prefix: 'apple.assetCatalogCompiler')`. A prefix passed
    /// as a parameter is not a literal and does not count. Sorted, each once.
    ///
    /// A formula that says `include 'apple'` selects what that plugin's prelude selects
    /// (B-108) — its prefixes are in the prelude's text, not the formula's — so each
    /// included prelude is read too, and the preludes it includes in turn.
    public static func namespaces(selectedIn formula: String) -> [String] {
        var selected = Set<String>()
        var pending  = [formula]
        var read     = Set<String>()
        while let text = pending.popLast() {
            selected.formUnion(captures(of: #"prefix:\s*'([A-Za-z][A-Za-z0-9.]*)'"#, in: text))
            for name in captures(of: #"include\s+'([^']+)'"#, in: text) where read.insert(name).inserted {
                if case .prelude(_, let prelude) = FormulaIncludeProviders.resolve(includeNamed: name) {
                    pending.append(prelude)
                }
            }
        }
        return selected.sorted()
    }

    /// The first capture group of every match of `pattern` in `text`.
    private static func captures(of pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
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

    /// One block per namespace in `namespaces`, in the shape `semel tools` prints, plus the
    /// platform settings each tool needs. Only the namespaces the formula selects from,
    /// because the engine reports a key no filter claims as unused on every build. A tool
    /// installed in several versions is pinned to the newest; a tool not installed leaves
    /// a comment saying so, so the file still says what is missing.
    public static func config(platform: Platform, deploymentVersion: String, facts: ToolchainFacts,
                              namespaces: [String]) throws -> String {
        guard let sdkIdentity = facts.sdkIdentity(platform.sdkName),
              let sdkPath = facts.sdkPath(platform.sdkName) else {
            throw Vendoring.Failure(description: "no \(platform.sdkName) SDK on this machine (xcrun --sdk \(platform.sdkName))")
        }
        let target = platform.target(deploymentVersion: deploymentVersion)
        let wanted = Set(namespaces)

        var blocks: [String] = [
            """
            // Written by semel-swift prepare for --platform \(platform.rawValue): the tools and SDK
            // this machine has, and the deployment version the packages declare, for the
            // namespaces the formula reads. Edit to pin another toolchain; `semel tools`
            // lists what is installed.
            """,
        ]
        for entry in facts.namespaces.sorted(by: { $0.namespace < $1.namespace }) where wanted.contains(entry.namespace) {
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
            for (key, value) in platformSettings(toolName: entry.toolName, platform: platform,
                                                 sdkIdentity: sdkIdentity, sdkPath: sdkPath, target: target,
                                                 deploymentVersion: deploymentVersion) {
                lines.append("\(entry.namespace).\(key)=\(value)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The settings a tool's nodes read besides the descriptor, by tool. The Swift
    /// compiler and linker take the SDK by name and check its identity; clang takes it as
    /// a path and needs the C standards stated; actool takes the platform by name with
    /// the deployment version and devices that decide what it compiles. The package
    /// reader and xcstringstool declare nothing.
    private static func platformSettings(toolName: String, platform: Platform, sdkIdentity: String,
                                         sdkPath: String, target: String, deploymentVersion: String) -> [(String, String)] {
        switch toolName {
        case "swiftc":
            return [("sdk", platform.sdkName), ("sdkVersion", sdkIdentity), ("target", target)]
        case "clang":
            return [("sdkPath", sdkPath), ("target", target), ("cStandard", cStandard), ("cxxStandard", cxxStandard)]
        case "actool":
            return [("platform", platform.sdkName), ("minimumDeploymentTarget", deploymentVersion),
                    ("targetDevices", platform.targetDevices)]
        default:
            return []
        }
    }
}
