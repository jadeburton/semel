//
//  Preparation.swift
//  SemelSwiftTool
//
//  `semel-swift prepare <folder> --platform <name>`: everything between cloning a tree of
//  Swift packages and `semel 'build <folder>'`. Finds the packages, takes as roots the
//  ones nothing depends on by path, vendors their closure into one `Dependencies`, and
//  writes the formula and the two config files beside them. Never overwrites the formula
//  or the project's config: a project that ships its own has already decided. Its part of
//  the machine's config is rewritten every run: it is generated and nobody edits it, and
//  what another writer put there is kept.

import Foundation
import SemelApple
import SemelMachineFile
import SemelNodeKit

public struct PrepareReport: Equatable {
    /// The `.xcodeproj` the folder holds, when it is a project rather than packages.
    public var project: String?
    /// The project's local packages, as its converter finds them: the ones it declares and
    /// the ones directly in its synchronized folders.
    public var localPackages: [URL] = []
    public var roots: [PackageSummary] = []
    public var vendored: [Vendoring.Copied] = []
    /// The lock written beside each vendored copy (B-06), one per copy.
    public var locks: [URL] = []
    /// Every binary target's `path:` zip unzipped into its package's `semel-artifacts`.
    public var unzippedArtifacts: [URL] = []
    /// Every binary target's folder in `semel-artifacts` that holds its artifact, copied
    /// from resolution's download or unzipped (B-77).
    public var artifacts: [URL] = []
    public var written: [URL] = []
    public var kept: [URL] = []
    /// What another writer put in the machine file and prepare kept, by writer (B-109).
    public var machineFileKept: [MachineFile.Kept] = []
    /// An xcconfig the project names that was not there, now in place as a copy of
    /// `source`: the file named on the command line for it, or a template beside it.
    public struct TemplateCopy: Equatable {
        public var file: URL
        public var source: URL

        public init(file: URL, source: URL) {
            self.file   = file
            self.source = source
        }
    }

    public var copiedFromTemplate: [TemplateCopy] = []
    /// The xcconfig files the project names that are not there and nothing provides: the
    /// converter reads each as an empty layer, and the build fails on what it would have
    /// defined.
    public var missingXcconfigs: [URL] = []
    /// When something is missing, the names the project's settings still reference after
    /// reading what is there — what the missing file would have to define. Empty when
    /// nothing is missing, whatever the project leaves undefined.
    public var undefinedReferences: [String] = []
    /// The sources the project generates before its build — a scheme pre-action running
    /// gyb — that are not there (B-77). Prepare runs no scheme action: it names them, and
    /// what would generate them, for the developer to run or write.
    public var ungeneratedSources: [XcodeProjectFacts.UngeneratedSource] = []
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

    /// `xcconfigSources` is the escape hatch for a project whose starting point for an
    /// ignored xcconfig is spelled in a way no template family covers: the path the
    /// project names, to the file to copy there.
    public static func run(folder: URL, platform: Platform, xcconfigSources: [String: URL] = [:],
                           steps: Steps = .live) throws -> PrepareReport {
        let folder = folder.standardizedFileURL
        let dependencies = folder.appendingPathComponent(Vendoring.dependenciesFolderName, isDirectory: true)
        var report = PrepareReport()
        let facts = try steps.facts()
        let sdkVersion = facts.sdkIdentity(platform.sdkName).map(GeneratedFiles.version(fromSDKIdentity:))
        let formula: String
        var namespaces: [String]
        var declaredVersion: String?
        // Every package the build reads, the tree's own and the vendored ones alike.
        var allSummaries: [PackageSummary] = []

        // A folder holding an `.xcodeproj` is a project: the project is the one root, it
        // says which packages it reaches, and its application's deployment target is the
        // build's. A folder without one is a tree of packages. The config carries the
        // namespaces the formula's converters read, and no other.
        if let project = try projectFile(in: folder) {
            report.project = project.lastPathComponent
            report.vendored = try steps.vendorProject(project, dependencies)
            // Before the project is read for its deployment target: an xcconfig is a
            // layer of the settings that reading evaluates.
            (report.copiedFromTemplate, report.missingXcconfigs) = try placeXcconfigs(ofProjectAt: project, sources: xcconfigSources)
            if !report.missingXcconfigs.isEmpty {
                report.undefinedReferences = try XcodeProjectFacts.undefinedReferences(ofProjectAt: project, sdk: platform.sdkName)
            }
            declaredVersion = try deploymentTarget(ofProjectAt: project, platform: platform)
            formula = GeneratedFiles.formula(project: project.lastPathComponent, platform: platform)
            // The packages the converter will find and include — the ones the project
            // declares and the ones in its synchronized folders — and what was vendored for
            // them decide the languages, by the rule a tree of packages is held to (B-110).
            report.localPackages = try XcodeProjectFacts.localPackagePaths(ofProjectAt: project)
                .map { folder.appendingPathComponent($0, isDirectory: true).standardizedFileURL }
                .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path) }
            let packageSummaries = try (report.localPackages + vendoredManifestFolders(in: dependencies)).map(steps.summarize)
            namespaces = GeneratedFiles.projectNamespaces(forCFamilyTargets: GeneratedFiles.hasCFamilyTargets(in: packageSummaries),
                                                          compiledSources: try XcodeProjectFacts.compiledSources(ofProjectAt: project))
            allSummaries = packageSummaries
            // A source the project generates before its build, not there: said here, with
            // what would generate it, since the build can only fail where it is used.
            report.ungeneratedSources = try XcodeProjectFacts.ungeneratedSources(ofProjectAt: project)
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
            // Which languages the tree holds is decided after vendoring, over the vendored
            // packages too: a C target that arrives with a dependency — swift-cmark under
            // IceCubes — is compiled through clang like one of the tree's own, and a scan
            // before the copy could not see it (B-122). The vendored packages are not roots
            // and say nothing about the deployment version; they only add languages.
            let vendoredSummaries = try vendoredManifestFolders(in: dependencies).map(steps.summarize)
            namespaces = GeneratedFiles.packageTreeNamespaces(
                forCFamilyTargets: GeneratedFiles.hasCFamilyTargets(in: summaries + vendoredSummaries))
            allSummaries = summaries + vendoredSummaries
        }

        // Every package's binary targets in its `semel-artifacts`, before the locks are
        // taken over the copies that hold them (B-77): a `path:` zip unzipped here; what a
        // `url:` names was copied from resolution's download with its checkout.
        report.unzippedArtifacts = try unzipArtifacts(of: allSummaries)
        report.artifacts = artifactFolders(of: allSummaries)
        report.locks = try writeLocks(for: report.vendored, summaries: allSummaries)

        // A formula already there is kept, and it may select namespaces the one written
        // here would not — a hand-written app formula compiles catalogs. What it selects
        // joins the config, so the file is not the one thing prepare left it to write.
        let formulaFile = folder.appendingPathComponent(GeneratedFiles.formulaFileName)
        if let kept = try? String(contentsOf: formulaFile, encoding: .utf8) {
            namespaces = Array(Set(namespaces).union(MachineFile.namespaces(selectedIn: kept))).sorted()
        }

        // No SDK for the platform is no build, whatever the manifests declare: said here,
        // once, rather than by every tool's missing-settings report.
        guard let sdkVersion else {
            throw Vendoring.Failure(description: "no \(platform.sdkName) SDK on this machine (xcrun --sdk \(platform.sdkName))")
        }
        let deploymentVersion = declaredVersion ?? sdkVersion
        let config = GeneratedFiles.projectConfig(platform: platform, deploymentVersion: deploymentVersion,
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

        // Prepare's part of the machine file is rewritten on every run: it is generated,
        // never edited, and the platform named on this run is what it should say (B-109).
        // Another writer's part is kept — `semel-clang` writes the clang namespaces for a
        // formula that includes both preludes — less any namespace prepare now writes.
        let machineFile = folder.appendingPathComponent(GeneratedFiles.machineConfigFileName)
        let existing = FileManager.default.fileExists(atPath: machineFile.path)
            ? try String(contentsOf: machineFile, encoding: .utf8)
            : nil
        let section = GeneratedFiles.machineSection(platform: platform, facts: facts, namespaces: namespaces)
        let (machineText, merge) = MachineFile.merging(section, into: existing)
        try machineText.write(to: machineFile, atomically: true, encoding: .utf8)
        report.written.append(machineFile)
        report.machineFileKept = merge?.kept ?? []
        return report
    }

    /// A lock beside every copy, once every copy is in place (B-06): several roots vendor
    /// into one folder and a name two of them resolve is copied by the later one, so the
    /// lock is taken over the copy that stayed, with the pin of the root that copied it,
    /// and each binary target's checksum from the copy's manifest in `summaries` (B-77).
    static func writeLocks(for vendored: [Vendoring.Copied], summaries: [PackageSummary] = []) throws -> [URL] {
        var lastCopy: [URL: Vendoring.Copied] = [:]
        for copied in vendored {
            lastCopy[copied.destination.standardizedFileURL] = copied
        }
        return try lastCopy.keys.sorted { $0.path < $1.path }.compactMap { destination in
            guard let copied = lastCopy[destination] else {
                return nil
            }
            let summary = summaries.first { $0.folder.standardizedFileURL.path == destination.path }
            var checksums: [String: String] = [:]
            for binaryTarget in summary?.binaryTargets ?? [] {
                checksums[binaryTarget.name] = binaryTarget.checksum
            }
            return try Vendoring.writeLock(for: copied, artifacts: checksums)
        }
    }

    /// Unzips every binary target's `path:` zip into its package's `semel-artifacts`, as
    /// SwiftPM extracts one before it builds, and returns the zips. A zip that is not
    /// there is left to the converter to name.
    static func unzipArtifacts(of summaries: [PackageSummary]) throws -> [URL] {
        var unzipped: [URL] = []
        for summary in summaries.sorted(by: { $0.folder.path < $1.folder.path }) {
            for binaryTarget in summary.binaryTargets {
                guard let path = binaryTarget.path, path.hasSuffix(".zip") else {
                    continue
                }
                let zip = summary.folder.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: zip.path) else {
                    continue
                }
                try Vendoring.unzipArtifact(zip, target: binaryTarget.name, into: summary.folder)
                unzipped.append(zip)
            }
        }
        return unzipped
    }

    /// Every binary target's folder in its package's `semel-artifacts` that holds
    /// something, sorted: what the build will find.
    static func artifactFolders(of summaries: [PackageSummary]) -> [URL] {
        summaries.flatMap { summary in
            summary.binaryTargets.compactMap { binaryTarget -> URL? in
                let folder = summary.folder.appendingPathComponent(Vendoring.artifactsFolderName, isDirectory: true)
                                           .appendingPathComponent(binaryTarget.name, isDirectory: true)
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                return contents.isEmpty ? nil : folder
            }
        }.sorted { $0.path < $1.path }
    }

    /// Every package vendored under `dependencies`, none when nothing was: each folder
    /// directly in it that holds a manifest, and nothing below. A vendored checkout is one
    /// package; what it keeps deeper is its own — purchases-ios has a `Tests/Package.swift`
    /// that does not even parse on its own — and `dump-package` on such a folder failed
    /// the whole `prepare` of the IceCubes app (2026-09-29).
    static func vendoredManifestFolders(in dependencies: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dependencies.path) else {
            return []
        }
        let children = try fileManager.contentsOfDirectory(at: dependencies,
                                                           includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles])
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { PackageScan.isManifest($0.appendingPathComponent("Package.swift")) }
            .map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
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

    /// Xcode knows no template. A repository that ignores an xcconfig and ships a starting
    /// point for it spells the name its own way; these are the spellings seen, as a
    /// trailing extension (`App.xcconfig.template`) or a marker before the extension
    /// (`App.example.xcconfig`, `App-sample.xcconfig`). The stem must be the named file's,
    /// so a sibling that merely resembles it is never copied.
    static let templateMarkers = ["template", "example", "sample", "dist"]

    /// The files that would be a template for `xcconfig`, in the order they are tried.
    static func templateCandidates(for xcconfig: URL) -> [URL] {
        let folder = xcconfig.deletingLastPathComponent()
        let name = xcconfig.lastPathComponent
        let stem = xcconfig.deletingPathExtension().lastPathComponent
        let ext  = xcconfig.pathExtension
        return templateMarkers.flatMap { marker in
            ["\(name).\(marker)", "\(stem).\(marker).\(ext)", "\(stem)-\(marker).\(ext)"]
        }.map { folder.appendingPathComponent($0) }
    }

    /// The xcconfig files the project names, each put in place when it is not there: from
    /// the source named for it on the command line, or else from a template beside it.
    /// One that is there is never touched: it is the user's, whatever a template says
    /// now. Returns the copies made and the files still missing, so the report can say
    /// both. A source named for a file the project does not name is a mistake worth
    /// stopping on, since nothing would ever read the copy.
    static func placeXcconfigs(ofProjectAt project: URL,
                               sources: [String: URL]) throws -> (copied: [PrepareReport.TemplateCopy], missing: [URL]) {
        let folder = project.deletingLastPathComponent()
        let named = try XcodeProjectFacts.xcconfigPaths(ofProjectAt: project)
        for path in sources.keys.sorted() where !named.contains(path) {
            throw Vendoring.Failure(description: "--xcconfig \(path): the project names no such file; it names \(named.isEmpty ? "none" : named.joined(separator: ", "))")
        }

        var copied: [PrepareReport.TemplateCopy] = []
        var missing: [URL] = []
        for relativePath in named {
            let xcconfig = folder.appendingPathComponent(relativePath)
            guard !FileManager.default.fileExists(atPath: xcconfig.path) else {
                continue
            }
            if let source = sources[relativePath] {
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw Vendoring.Failure(description: "--xcconfig \(relativePath)=\(source.path): no such file")
                }
                try FileManager.default.copyItem(at: source, to: xcconfig)
                copied.append(.init(file: xcconfig, source: source))
            } else if let template = templateCandidates(for: xcconfig).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                try FileManager.default.copyItem(at: template, to: xcconfig)
                copied.append(.init(file: xcconfig, source: template))
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
