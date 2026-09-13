//
//  Initialization.swift
//  SemelVendor
//
//  `semel-vendor init <folder> --platform <name>`: everything between cloning a tree of
//  Swift packages and `semel 'build <folder>'`. Finds the packages, takes as roots the
//  ones nothing depends on by path, vendors their closure into one `Dependencies`, and
//  writes the formula and config beside them. Never overwrites a file that is there: a
//  project that ships its own formula or config has already decided.

import Foundation

public struct InitReport: Equatable {
    public var roots: [PackageSummary] = []
    public var vendored: [Vendoring.Copied] = []
    public var written: [URL] = []
    public var kept: [URL] = []
}

public enum Initialization {

    /// The steps that touch the machine, so a test can run the rest against a tree it
    /// wrote itself.
    public struct Steps {
        public var summarize: (URL) throws -> PackageSummary
        public var vendor: ([URL], URL) throws -> [Vendoring.Copied]
        public var facts: () throws -> ToolchainFacts

        public init(summarize: @escaping (URL) throws -> PackageSummary,
                    vendor: @escaping ([URL], URL) throws -> [Vendoring.Copied],
                    facts: @escaping () throws -> ToolchainFacts) {
            self.summarize = summarize
            self.vendor    = vendor
            self.facts     = facts
        }

        public static let live = Steps(summarize: PackageScan.summary(ofPackageAt:),
                                       vendor: Vendoring.vendor(packageRoots:into:),
                                       facts: ToolchainFacts.fromMachine)
    }

    public static func run(folder: URL, platform: Platform, steps: Steps = .live) throws -> InitReport {
        let folder = folder.standardizedFileURL
        let manifestFolders = try PackageScan.manifestFolders(under: folder)
        guard !manifestFolders.isEmpty else {
            throw Vendoring.Failure(description: "no Package.swift under \(folder.path)")
        }

        var report = InitReport()
        let summaries = try manifestFolders.map(steps.summarize)
        report.roots = PackageScan.roots(of: summaries)

        report.vendored = try steps.vendor(report.roots.map(\.folder),
                                           folder.appendingPathComponent(Vendoring.dependenciesFolderName, isDirectory: true))

        let facts = try steps.facts()
        let deploymentVersion = try InitFiles.deploymentVersion(for: platform, in: summaries)
            ?? facts.sdkIdentity(platform.sdkName).map(InitFiles.version(fromSDKIdentity:))
            ?? { throw Vendoring.Failure(description: "no \(platform.sdkName) SDK on this machine (xcrun --sdk \(platform.sdkName))") }()

        let formula = InitFiles.formula(rootPaths: report.roots.map { relativePath(of: $0.folder, under: folder) })
        let config  = try InitFiles.config(platform: platform, deploymentVersion: deploymentVersion, facts: facts)

        for (name, contents) in [(InitFiles.formulaFileName, formula), (InitFiles.configFileName, config)] {
            let file = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                report.kept.append(file)
            } else {
                try contents.write(to: file, atomically: true, encoding: .utf8)
                report.written.append(file)
            }
        }
        return report
    }

    /// `<folder>/Packages/Timeline` under `<folder>` is `Packages/Timeline`; the folder
    /// itself is `.`, the path a formula names with `<.>`.
    static func relativePath(of packageFolder: URL, under folder: URL) -> String {
        let base = folder.standardizedFileURL.path
        let path = packageFolder.standardizedFileURL.path
        guard path != base else {
            return "."
        }
        guard path.hasPrefix(base + "/") else {
            return path
        }
        return String(path.dropFirst(base.count + 1))
    }
}
