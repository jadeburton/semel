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
    /// `application` is written only when given: without it the converter builds the
    /// application the platform picks.
    public static func formula(project: String, platform: Platform, application: String? = nil) -> String {
        let named = application.map { ", application: \(formulaQuoted($0))" } ?? ""
        return """
        // Written by semel-swift prepare. The project is the root: its converter brings every
        // package it references and builds the application and the extensions it embeds.
        include XcodeProjectConverter(path: <\(project)>, root: <.>, configuration: 'Debug', sdk: '\(platform.sdkName)'\(named)).formula

        """
    }

    /// A formula string literal takes whichever quote the value does not hold.
    static func formulaQuoted(_ value: String) -> String {
        value.contains("'") ? "\"\(value)\"" : "'\(value)'"
    }

    /// The config namespaces the formula for a tree of packages selects from: what
    /// `SwiftFormulaConverter` emits reads — the clang ones only when a target is a
    /// C-family one, since a block nothing reads is reported as unused on every build.
    public static func packageTreeNamespaces(forCFamilyTargets hasCFamilyTargets: Bool) -> [String] {
        SemelSwift.converterConfigNamespaces(forCFamilyTargets: hasCFamilyTargets)
    }

    /// Whether any of a tree's targets is compiled through clang, read from the target
    /// folders on disk by the converter's own rule: every file at any depth within the
    /// target's `sources:` and `exclude:`, hidden folders left out as the converter's walk
    /// leaves them. The paths are the enumerator's own relative ones, which do not depend
    /// on how the folder's URL spells a symlink above it (`/tmp`).
    public static func hasCFamilyTargets(in summaries: [PackageSummary]) -> Bool {
        summaries.flatMap(\.targets).contains { target in
            let enumerator = FileManager.default.enumerator(atPath: target.folder.path)
            var relativePaths: [String] = []
            while let path = enumerator?.nextObject() as? String {
                guard !(path as NSString).lastPathComponent.hasPrefix(".") else {
                    enumerator?.skipDescendants()
                    continue
                }
                relativePaths.append(path)
            }
            return SemelSwift.isCFamilyTargetFolder(holding: relativePaths, sources: target.sources, exclude: target.exclude)
        }
    }

    /// Whether any of a tree's targets holds a xib or a storyboard, which its package's
    /// formula compiles with ibtool into the target's resource bundle (B-77) — read from
    /// the target folders on disk, less what the manifest excludes, hidden folders left out.
    public static func hasInterfaceBuilderDocuments(in summaries: [PackageSummary]) -> Bool {
        summaries.flatMap(\.targets).contains { target in
            let enumerator = FileManager.default.enumerator(atPath: target.folder.path)
            while let path = enumerator?.nextObject() as? String {
                let name = (path as NSString).lastPathComponent
                guard !name.hasPrefix(".") else {
                    enumerator?.skipDescendants()
                    continue
                }
                let excluded = target.exclude.contains { exclusion in
                    let trimmed = exclusion.hasSuffix("/") ? String(exclusion.dropLast()) : exclusion
                    return path == trimmed || path.hasPrefix(trimmed + "/")
                }
                if !excluded, ["xib", "storyboard"].contains((name as NSString).pathExtension.lowercased()) {
                    return true
                }
            }
            return false
        }
    }

    /// The config namespaces the formula for a project selects from: what the project
    /// converter emits for its own targets reads, and what the package formulas it
    /// includes read — the clang ones only when one of those packages has a C-family
    /// target, as for a tree, or the application's targets have a C-family source,
    /// ibtool's only when they have a xib or a storyboard, and codesign's only for the Mac,
    /// whose bundles are signed (B-77). Each once.
    public static func projectNamespaces(forCFamilyTargets hasCFamilyTargets: Bool,
                                         compiledSources: XcodeProjectFacts.CompiledSources,
                                         platform: Platform) -> [String] {
        let own = XcodeProjectConverter.configNamespaces(
            compilingCFamilySources: compiledSources.hasCFamilySources,
            compilingInterfaceBuilderDocuments: compiledSources.hasInterfaceBuilderDocuments,
            signingBundles: XcodeProjectConverter.signsBundles(forSDK: platform.sdkName))
        var namespaces: [String] = []
        for namespace in own + SemelSwift.converterConfigNamespaces(forCFamilyTargets: hasCFamilyTargets)
        where !namespaces.contains(namespace) {
            namespaces.append(namespace)
        }
        return namespaces
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
        MachineFile.text(of: [machineSection(platform: platform, facts: facts, namespaces: namespaces)])
    }

    /// Prepare's part of the machine file, to lay into one another writer may have written
    /// (B-109): `semel-clang` writes the clang namespaces beside a formula of its own.
    public static func machineSection(platform: Platform, facts: ToolchainFacts, namespaces: [String]) -> MachineFile.Section {
        let wanted = Set(namespaces)
        return MachineFile.section(writtenBy: machineFileWriter, platform: platform, descriptors: facts.descriptors,
                                   namespaces: facts.namespaces.filter { wanted.contains($0.namespace) })
    }

    /// Who the machine file says wrote prepare's part: the command the Swift namespaces
    /// register as their writer.
    static let machineFileWriter = "semel-swift prepare"

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

    // MARK: - Reading back what the files already say

    /// The target triple a project config holds, read as the engine reads the file: the
    /// first `<namespace>.target` by key, since prepare writes one triple to every
    /// namespace that takes one. Nil when the config states none — a hand-written one may
    /// configure no compiler at all.
    public static func target(inProjectConfig text: String) -> String? {
        let settings = [String: String](plainText: text)
        return settings.keys.sorted().first { $0.hasSuffix(".target") }.flatMap { settings[$0] }
    }

    /// The `sdk:` an `XcodeProjectConverter` in a formula is given: what platform a
    /// project formula builds for. Nil when no converter is constructed — a hand-written
    /// formula that says nothing about the platform — or it is given no `sdk:`. Comment
    /// lines are left out, as the parser leaves them out.
    public static func converterSDK(inFormula text: String) -> String? {
        let formulaText = text.components(separatedBy: "\n")
            .filter { !$0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") }
            .joined(separator: "\n")
        guard let arguments = firstCapture(of: #"\bXcodeProjectConverter\s*\(([^)]*)\)"#, in: formulaText) else {
            return nil
        }
        return firstCapture(of: #"(?:^|[\s,])sdk\s*:\s*'([^']*)'"#, in: arguments)
            ?? firstCapture(of: #"(?:^|[\s,])sdk\s*:\s*"([^"]*)""#, in: arguments)
    }

    private static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// The project file's lines for one namespace, by tool. The Swift compiler and linker
    /// and the clang tools take the target triple; clang also wants the language standards
    /// stated, which are the project's to choose; actool takes the platform by name with
    /// the deployment version and devices that decide what it compiles, and ibtool the same
    /// version and devices, its platform being the SDK it is told. A comment is a
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
        case "ibtool":
            // The platform is the SDK's, a machine setting; what the project decides is
            // what actool is told too.
            return ["\(namespace).minimumDeploymentTarget=\(deploymentVersion)",
                    "\(namespace).targetDevices=\(platform.targetDevices)"]
        default:
            return []
        }
    }
}
