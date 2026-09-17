//
//  Preparation.swift
//  SemelSwiftTool
//
//  `semel-swift prepare <folder> --platform <name>`: everything between cloning a tree of
//  Swift packages and `semel 'build <folder>'`. Finds the packages, takes as roots the
//  ones nothing depends on by path, vendors their closure into one `Dependencies`, and
//  writes the formula and config beside them. Never overwrites a file that is there: a
//  project that ships its own formula or config has already decided.

import Foundation
import SemelApple

public struct PrepareReport: Equatable {
    /// The `.xcodeproj` the folder holds, when it is a project rather than packages.
    public var project: String?
    public var roots: [PackageSummary] = []
    public var vendored: [Vendoring.Copied] = []
    public var written: [URL] = []
    public var kept: [URL] = []
    /// The xcconfig files the project names that were not there and had a `.template`
    /// beside them, now in place as copies of it.
    public var copiedFromTemplate: [URL] = []
    /// The xcconfig files the project names that are not there and have no template: the
    /// converter reads each as an empty layer, and the build fails on what it would have
    /// defined.
    public var missingXcconfigs: [URL] = []
}

public enum Preparation {

    /// The steps that touch the machine, so a test can run the rest against a tree it
    /// wrote itself.
    public struct Steps {
        public var summarize: (URL) throws -> PackageSummary
        public var vendor: ([URL], URL) throws -> [Vendoring.Copied]
        public var vendorProject: (URL, URL) throws -> [Vendoring.Copied]
        public var facts: () throws -> ToolchainFacts

        public init(summarize: @escaping (URL) throws -> PackageSummary,
                    vendor: @escaping ([URL], URL) throws -> [Vendoring.Copied],
                    vendorProject: @escaping (URL, URL) throws -> [Vendoring.Copied] = { _, _ in [] },
                    facts: @escaping () throws -> ToolchainFacts) {
            self.summarize     = summarize
            self.vendor        = vendor
            self.vendorProject = vendorProject
            self.facts         = facts
        }

        public static let live = Steps(summarize: PackageScan.summary(ofPackageAt:),
                                       vendor: Vendoring.vendor(packageRoots:into:),
                                       vendorProject: Vendoring.vendor(project:into:),
                                       facts: ToolchainFacts.fromMachine)
    }

    public static func run(folder: URL, platform: Platform, steps: Steps = .live) throws -> PrepareReport {
        let folder = folder.standardizedFileURL
        let dependencies = folder.appendingPathComponent(Vendoring.dependenciesFolderName, isDirectory: true)
        var report = PrepareReport()
        let facts = try steps.facts()
        let sdkVersion = facts.sdkIdentity(platform.sdkName).map(GeneratedFiles.version(fromSDKIdentity:))
        let formula: String
        let namespaces: [String]
        var declaredVersion: String?

        // A folder holding an `.xcodeproj` is a project: the project is the one root, it
        // says which packages it reaches, and its application's deployment target is the
        // build's. A folder without one is a tree of packages. The config carries the
        // namespaces the formula's converters read, and no other.
        if let project = try projectFile(in: folder) {
            report.project = project.lastPathComponent
            report.vendored = try steps.vendorProject(project, dependencies)
            // Before the project is read for its deployment target: an xcconfig is a
            // layer of the settings that reading evaluates.
            (report.copiedFromTemplate, report.missingXcconfigs) = try placeXcconfigs(ofProjectAt: project)
            declaredVersion = try deploymentTarget(ofProjectAt: project, platform: platform)
            formula = GeneratedFiles.formula(project: project.lastPathComponent, platform: platform)
            namespaces = GeneratedFiles.projectNamespaces
        } else {
            let manifestFolders = try PackageScan.manifestFolders(under: folder)
            guard !manifestFolders.isEmpty else {
                throw Vendoring.Failure(description: "no Package.swift and no .xcodeproj under \(folder.path)")
            }
            let summaries = try manifestFolders.map(steps.summarize)
            report.roots = PackageScan.roots(of: summaries)
            report.vendored = try steps.vendor(report.roots.map(\.folder), dependencies)
            declaredVersion = GeneratedFiles.deploymentVersion(for: platform, in: summaries)
            formula = GeneratedFiles.formula(rootPaths: report.roots.map { relativePath(of: $0.folder, under: folder) })
            namespaces = GeneratedFiles.packageTreeNamespaces
        }

        guard let deploymentVersion = declaredVersion ?? sdkVersion else {
            throw Vendoring.Failure(description: "no \(platform.sdkName) SDK on this machine (xcrun --sdk \(platform.sdkName))")
        }
        let config = try GeneratedFiles.config(platform: platform, deploymentVersion: deploymentVersion,
                                               facts: facts, namespaces: namespaces)

        for (name, contents) in [(GeneratedFiles.formulaFileName, formula), (GeneratedFiles.configFileName, config)] {
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

    /// The one `.xcodeproj` directly in `folder`, if there is one; two is a question the
    /// tool cannot answer. Only the top level: a package's fixtures may hold projects.
    static func projectFile(in folder: URL) throws -> URL? {
        let projects = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".xcodeproj") }
            .sorted()
        guard projects.count <= 1 else {
            throw Vendoring.Failure(description: "\(folder.path) holds several projects: \(projects.joined(separator: ", ")); prepare one folder per project")
        }
        return projects.first.map { folder.appendingPathComponent($0, isDirectory: true) }
    }

    /// The application target's deployment target for the platform, evaluated the way
    /// the converter will evaluate it. Nil when the project states none.
    static func deploymentTarget(ofProjectAt project: URL, platform: Platform) throws -> String? {
        try XcodeProjectFacts.deploymentTarget(ofProjectAt: project, sdk: platform.sdkName)
    }

    /// What a file the project names but the repository does not ship is called when the
    /// repository ships a starting point for it instead: `IceCubesApp.xcconfig.template`
    /// beside the ignored `IceCubesApp.xcconfig`.
    public static let templateSuffix = ".template"

    /// The xcconfig files the project names, each put in place from its template when it
    /// is not there and the template is. One that is there is never touched: it is the
    /// user's, whatever the template says now. Returns the copies made and the files
    /// still missing, so the report can say both.
    static func placeXcconfigs(ofProjectAt project: URL) throws -> (copied: [URL], missing: [URL]) {
        let folder = project.deletingLastPathComponent()
        var copied: [URL] = []
        var missing: [URL] = []
        for relativePath in try XcodeProjectFacts.xcconfigPaths(ofProjectAt: project) {
            let xcconfig = folder.appendingPathComponent(relativePath)
            guard !FileManager.default.fileExists(atPath: xcconfig.path) else {
                continue
            }
            let template = URL(fileURLWithPath: xcconfig.path + templateSuffix)
            if FileManager.default.fileExists(atPath: template.path) {
                try FileManager.default.copyItem(at: template, to: xcconfig)
                copied.append(xcconfig)
            } else {
                missing.append(xcconfig)
            }
        }
        return (copied, missing)
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
