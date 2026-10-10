//
//  Preparation.swift
//  SemelSwiftTool
//
//  `semel-swift prepare <folder> --platform <name>`: everything between cloning a tree of
//  Swift packages and `semel 'build <folder>'`. Finds the packages, takes as roots the
//  ones nothing depends on by path, vendors their closure into one `Dependencies`, and
//  writes the formula and the two config files beside them. Never overwrites the formula
//  or the project's config: a project that ships its own has already decided, and a
//  `--platform` they do not build for stops the run. Its part of the machine's config is
//  rewritten every run: it is generated and nobody edits it, and what another writer put
//  there is kept.

import Foundation
import SemelApple
import SemelMachineFile
import SemelNodeKit

public struct PrepareReport: Equatable {
    /// The `.xcodeproj` the folder holds, when it is a project rather than packages.
    public var project: String?
    /// The application target the build is for, which the platform picked or
    /// `--application` named (B-77).
    public var application: String?
    /// The project's local packages, as its converter finds them: the ones it declares and
    /// the ones directly in its synchronized folders.
    public var localPackages: [URL] = []
    public var roots: [PackageSummary] = []
    /// Every checkout resolution produced, in the order vendoring met them: a name two
    /// roots resolve is here twice, and the later entry is the one that stood.
    public var vendored: [Vendoring.Copied] = []
    /// One vendored package copied on this run, and why: a first copy, a pin that moved, or
    /// a copy or lock that was not right (B-138).
    public struct Revendored: Equatable {
        public var name: String
        public var reason: Vendoring.CopyReason
        /// What the copy is now, as the lock beside it records.
        public var pin: Vendoring.Pin?

        public init(name: String, reason: Vendoring.CopyReason, pin: Vendoring.Pin?) {
            self.name   = name
            self.reason = reason
            self.pin    = pin
        }
    }

    /// The packages copied on this run, by name, one per copy (B-138).
    public var revendored: [Revendored] = []
    /// The packages whose copy and lock were already right and were left untouched, by
    /// name: their content roots did not move, so nothing downstream of them rebuilds.
    public var unchanged: [String] = []
    /// The lock written beside each copy made on this run (B-06), one per copy. A copy left
    /// untouched keeps the lock it had.
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
    /// What the build is for, as the files the build reads say it: set by every run that
    /// gets as far as writing them.
    public var buildsFor: BuildsFor?

    /// Whether a file prepare never overwrites was written on this run or was there.
    public enum FileOrigin: Equatable {
        case written
        case alreadyThere
    }

    /// The platform a run prepared for, with what `semel.config` carries for it — read
    /// back from the file after the run, so that a config that was there is reported as
    /// it is rather than as the flag would have written it.
    public struct BuildsFor: Equatable {
        public var platform: Platform
        /// The version of the platform's SDK on this machine, which the machine file names.
        public var sdkVersion: String
        /// The target triple `semel.config` carries; nil when it states none.
        public var target: String?
        public var config: FileOrigin
        /// A project formula's `sdk:` for its converter, and whether the formula was
        /// written; nil for a tree of packages, or a formula that constructs no converter.
        public var converterSDK: ConverterSDK?

        public struct ConverterSDK: Equatable {
            public var sdk: String
            public var formula: FileOrigin

            public init(sdk: String, formula: FileOrigin) {
                self.sdk     = sdk
                self.formula = formula
            }
        }

        public init(platform: Platform, sdkVersion: String, target: String?, config: FileOrigin,
                    converterSDK: ConverterSDK? = nil) {
            self.platform     = platform
            self.sdkVersion   = sdkVersion
            self.target       = target
            self.config       = config
            self.converterSDK = converterSDK
        }
    }
}

// MARK: - What the build is for, as `prepare` prints it

extension PrepareReport {

    /// `Platform: ios-simulator, SDK iphonesimulator 26.0, target arm64-apple-ios17.0-simulator
    /// (semel.config written)`, every run: a default platform or a config already there is
    /// otherwise invisible until a build fails on a module the platform does not have. A
    /// project adds the line for its formula's converter.
    public var platformLines: [String] {
        guard let buildsFor else {
            return []
        }
        let target = buildsFor.target.map { "target \($0)" } ?? "no target"
        var lines = ["Platform: \(buildsFor.platform.rawValue), SDK \(buildsFor.platform.sdkName) \(buildsFor.sdkVersion), "
                     + "\(target) (\(Self.origin(of: GeneratedFiles.configFileName, buildsFor.config)))"]
        if let converter = buildsFor.converterSDK {
            lines.append("Converter: sdk \(converter.sdk) (\(Self.origin(of: GeneratedFiles.formulaFileName, converter.formula)))")
        }
        return lines
    }

    static func origin(of fileName: String, _ origin: FileOrigin) -> String {
        switch origin {
        case .written:      return "\(fileName) written"
        case .alreadyThere: return "from the \(fileName) already there"
        }
    }
}

// MARK: - A platform the files already there do not build for

/// A setting in a file prepare never overwrites that says what the build is for: the
/// target triple in `semel.config`, or the `sdk:` a project formula gives its converter.
public struct HeldPlatform: Equatable {
    public enum Setting: Equatable {
        case target(String)
        case converterSDK(String)
    }

    public var file: URL
    public var setting: Setting

    public init(file: URL, setting: Setting) {
        self.file    = file
        self.setting = setting
    }

    /// The platform the setting is for; nil when it is none prepare builds for.
    public var platform: Platform? {
        switch setting {
        case .target(let target):    return Platform(target: target)
        case .converterSDK(let sdk): return Platform(sdkName: sdk)
        }
    }

    var sentence: String {
        let what: String
        switch setting {
        case .target(let target):    what = "holds target \(target)"
        case .converterSDK(let sdk): what = "gives its converter sdk '\(sdk)'"
        }
        let platformName = platform.map { "which is \($0.rawValue)" } ?? "which is no platform prepare builds for"
        return "\(file.path) \(what), \(platformName)"
    }
}

/// Prepare never overwrites the formula or the project config, so a platform they do not
/// build for cannot be prepared over them: the run stops before writing anything, rather
/// than leave a build that fails later on a module the platform does not have.
public enum PlatformConflict: Error, Equatable, CustomStringConvertible {
    /// `--platform` names one platform and the files already there hold another.
    case flagDisagrees(asked: Platform, held: [HeldPlatform], disagreeing: [HeldPlatform])
    /// No `--platform`, and the files already there do not agree on one platform prepare
    /// builds for, so there is none to keep.
    case noOnePlatformHeld(held: [HeldPlatform])

    public var description: String {
        switch self {
        case .flagDisagrees(let asked, let held, let disagreeing):
            let names = Self.fileNames(of: disagreeing)
            let pronoun = disagreeing.count == 1 ? "it" : "them"
            var remedy = "delete \(names) to write \(pronoun) for \(asked.rawValue)"
            if let kept = Self.onePlatform(of: held) {
                remedy += ", or omit --platform to keep \(kept.rawValue)"
            }
            return disagreeing.map(\.sentence).joined(separator: "; ")
                + ", and --platform asks for \(asked.rawValue); \(remedy)"
        case .noOnePlatformHeld(let held):
            return held.map(\.sentence).joined(separator: "; ")
                + "; there is no one platform to keep: delete \(Self.fileNames(of: held)) to write "
                + "\(held.count == 1 ? "it" : "them") for --platform (\(Preparation.defaultPlatform.rawValue) when it is not given)"
        }
    }

    /// The one platform every held setting is for, if there is one.
    static func onePlatform(of held: [HeldPlatform]) -> Platform? {
        guard let platform = held.first?.platform, held.allSatisfy({ $0.platform == platform }) else {
            return nil
        }
        return platform
    }

    private static func fileNames(of held: [HeldPlatform]) -> String {
        held.map(\.file.lastPathComponent).joined(separator: " and ")
    }
}

// MARK: - What vendoring did, as `prepare` prints it

extension PrepareReport {

    /// One line per package copied on this run, then one counting the packages left as
    /// they were: `GRDB.swift 6.29.3 → 7.0.0, re-vendored` and `33 unchanged` (B-138).
    /// A line names what moved — the version, the revision when the version did not say
    /// (a branch pin, or a tag moved under its version), the origin when it was the
    /// repository that changed — and why a copy whose pin did not move was copied all the
    /// same.
    public var vendoringLines: [String] {
        var lines = revendored.map(Self.line(for:))
        if !unchanged.isEmpty {
            lines.append("\(unchanged.count) unchanged")
        }
        return lines
    }

    static func line(for revendored: Revendored) -> String {
        let now = Self.label(version: revendored.pin?.version, revision: revendored.pin?.revision)
        let named = now.map { "\(revendored.name) \($0)" } ?? revendored.name
        switch revendored.reason {
        case .absent:
            return "\(named), vendored"
        case .lockMissing:
            return "\(named), re-vendored: the copy had no lock"
        case .lockUnreadable(let error):
            return "\(named), re-vendored: its lock could not be read (\(error))"
        case .foldChanged(let lock):
            return "\(named), re-vendored: its lock was folded as \(lock.fold), and this prepare folds as \(FolderContentRoot.formatTag)"
        case .artifactsDiffer:
            return "\(named), re-vendored: its lock's binary-target checksums are not its manifest's"
        case .hiddenFilesDiffer:
            return "\(named), re-vendored: its lock's dot-named resources are not its manifest's"
        case .contentDiffers:
            return "\(named), re-vendored: the copy had changed since its lock was written"
        case .pinMoved(let lock):
            return "\(revendored.name) \(Self.movement(from: lock, to: revendored.pin)), re-vendored"
        }
    }

    /// What a pin moved by, in the terms that moved: the origin when the repository is
    /// another, else the version, else the revision.
    static func movement(from lock: DependencyLock, to pin: Vendoring.Pin?) -> String {
        let unpinned = "unpinned"
        guard lock.origin == pin?.origin else {
            return "\(lock.origin ?? unpinned) → \(pin?.origin ?? unpinned)"
        }
        guard lock.version == pin?.version else {
            let before = label(version: lock.version, revision: lock.revision) ?? unpinned
            let after  = label(version: pin?.version, revision: pin?.revision) ?? unpinned
            return "\(before) → \(after)"
        }
        let revisions = "\(lock.revision.map(abbreviated) ?? unpinned) → \(pin?.revision.map(abbreviated) ?? unpinned)"
        return lock.version.map { "\($0) \(revisions)" } ?? revisions
    }

    /// The version, or the revision a branch pin has instead, abbreviated as git does.
    static func label(version: String?, revision: String?) -> String? {
        version ?? revision.map(abbreviated)
    }

    static func abbreviated(_ revision: String) -> String {
        String(revision.prefix(7))
    }
}

public enum Preparation {

    /// The steps that touch the machine, so a test can run the rest against a tree it
    /// wrote itself.
    public struct Steps {
        public var summarize: (URL) throws -> PackageSummary
        /// Resolves the roots and vendors their checkouts into the folder, asking the
        /// checksums of an existing copy's manifest before it is left as it is.
        public var vendor: ([URL], URL, Vendoring.ReadManifestFacts) throws -> [Vendoring.Copied]
        public var vendorProject: (URL, URL, Vendoring.ReadManifestFacts) throws -> [Vendoring.Copied]
        public var facts: () throws -> ToolchainFacts

        public init(summarize: @escaping (URL) throws -> PackageSummary,
                    vendor: @escaping ([URL], URL, Vendoring.ReadManifestFacts) throws -> [Vendoring.Copied],
                    vendorProject: @escaping (URL, URL, Vendoring.ReadManifestFacts) throws -> [Vendoring.Copied] = { _, _, _ in [] },
                    facts: @escaping () throws -> ToolchainFacts) {
            self.summarize     = summarize
            self.vendor        = vendor
            self.vendorProject = vendorProject
            self.facts         = facts
        }

        public static let live = Steps(summarize: PackageScan.summary(ofPackageAt:),
                                       vendor: Vendoring.vendor(packageRoots:into:manifestFacts:),
                                       vendorProject: Vendoring.vendor(project:into:manifestFacts:),
                                       facts: ToolchainFacts.fromMachine)
    }

    /// `xcconfigSources` is the escape hatch for a project whose starting point for an
    /// ignored xcconfig is spelled in a way no template family covers: the path the
    /// project names, to the file to copy there.
    /// `application` names the application target to build when more than one builds for
    /// the platform; nil lets the platform pick, as the converter does.
    /// `requested` is `--platform`, nil when it is not given: the platform the files
    /// already there hold is then the run's, and `defaultPlatform` when they hold none.
    /// Given, it must be the one they hold (`PlatformConflict`).
    public static func run(folder: URL, platform requested: Platform?, application: String? = nil,
                           xcconfigSources: [String: URL] = [:], steps: Steps = .live) throws -> PrepareReport {
        let folder = folder.standardizedFileURL
        let dependencies = folder.appendingPathComponent(Vendoring.dependenciesFolderName, isDirectory: true)
        let configFile   = folder.appendingPathComponent(GeneratedFiles.configFileName)
        let formulaFile  = folder.appendingPathComponent(GeneratedFiles.formulaFileName)
        let projectFile  = try Self.projectFile(in: folder)
        // Before anything is vendored, copied or written: a conflict leaves the folder as
        // it was.
        let platform = try Self.platform(requested: requested,
                                         held: heldPlatforms(config: configFile, formula: projectFile == nil ? nil : formulaFile))
        var report = PrepareReport()
        let facts = try steps.facts()
        let sdkVersion = facts.sdkIdentity(platform.sdkName).map(GeneratedFiles.version(fromSDKIdentity:))
        let formula: String
        var namespaces: [String]
        var declaredVersion: String?
        // Every package the build reads, the tree's own and the vendored ones alike.
        var allSummaries: [PackageSummary] = []
        // A vendored copy's manifest is read before vendoring decides to leave the copy,
        // for the checksums its lock should record (B-138), and kept by folder: a copy left
        // as it was is the copy summarised below, so it is read once.
        var summariesReadWhileVendoring: [String: PackageSummary] = [:]
        let manifestFacts: Vendoring.ReadManifestFacts = { copy in
            let summary = try steps.summarize(copy)
            summariesReadWhileVendoring[copy.standardizedFileURL.path] = summary
            return Self.facts(of: summary)
        }
        let summarizeVendored: (URL) throws -> PackageSummary = { folder in
            try summariesReadWhileVendoring[folder.standardizedFileURL.path] ?? steps.summarize(folder)
        }
        // What was read of a copy that was then replaced describes the copy that went.
        func forgetReplacedCopies() {
            for copied in report.vendored where copied.change != .unchanged {
                summariesReadWhileVendoring[copied.destination.standardizedFileURL.path] = nil
            }
        }

        // A folder holding an `.xcodeproj` is a project: the project is the one root, it
        // says which packages it reaches, and its application's deployment target is the
        // build's. A folder without one is a tree of packages. The config carries the
        // namespaces the formula's converters read, and no other.
        if let project = projectFile {
            report.project = project.lastPathComponent
            report.vendored = try steps.vendorProject(project, dependencies, manifestFacts)
            forgetReplacedCopies()
            // Before the project is read for its deployment target: an xcconfig is a
            // layer of the settings that reading evaluates.
            (report.copiedFromTemplate, report.missingXcconfigs) = try placeXcconfigs(ofProjectAt: project, sources: xcconfigSources)
            if !report.missingXcconfigs.isEmpty {
                report.undefinedReferences = try XcodeProjectFacts.undefinedReferences(ofProjectAt: project, sdk: platform.sdkName,
                                                                                    application: application)
            }
            report.application = try XcodeProjectFacts.applicationName(ofProjectAt: project, sdk: platform.sdkName, named: application)
            declaredVersion = try deploymentTarget(ofProjectAt: project, platform: platform, application: application)
            formula = GeneratedFiles.formula(project: project.lastPathComponent, platform: platform, application: application)
            // The packages the converter will find and include — the ones the project
            // declares and the ones in its synchronized folders — and what was vendored for
            // them decide the languages, by the rule a tree of packages is held to (B-110).
            report.localPackages = try XcodeProjectFacts.localPackagePaths(ofProjectAt: project)
                .map { folder.appendingPathComponent($0, isDirectory: true).standardizedFileURL }
                .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Package.swift").path) }
            let packageSummaries = try report.localPackages.map(steps.summarize)
                + vendoredManifestFolders(in: dependencies).map(summarizeVendored)
            // ibtool's block when a package's resources hold a xib too, which its formula
            // compiles into the package's bundle (B-77).
            var compiledSources = try XcodeProjectFacts.compiledSources(ofProjectAt: project, sdk: platform.sdkName,
                                                                        application: application)
            compiledSources.hasInterfaceBuilderDocuments = compiledSources.hasInterfaceBuilderDocuments
                || GeneratedFiles.hasInterfaceBuilderDocuments(in: packageSummaries)
            namespaces = GeneratedFiles.projectNamespaces(forCFamilyTargets: GeneratedFiles.hasCFamilyTargets(in: packageSummaries),
                                                          compiledSources: compiledSources,
                                                          platform: platform)
            allSummaries = packageSummaries
            // A source the project generates before its build, not there: said here, with
            // what would generate it, since the build can only fail where it is used.
            report.ungeneratedSources = try XcodeProjectFacts.ungeneratedSources(ofProjectAt: project, sdk: platform.sdkName,
                                                                                  application: application)
        } else {
            let manifestFolders = try PackageScan.manifestFolders(under: folder)
            guard !manifestFolders.isEmpty else {
                throw Vendoring.Failure(description: "no Package.swift and no .xcodeproj under \(folder.path)")
            }
            let summaries = try manifestFolders.map(steps.summarize)
            report.roots = PackageScan.roots(of: summaries)
            report.vendored = try steps.vendor(report.roots.map(\.folder), dependencies, manifestFacts)
            forgetReplacedCopies()
            declaredVersion = GeneratedFiles.deploymentVersion(for: platform, in: summaries)
            formula = GeneratedFiles.formula(rootPaths: report.roots.map { relativePath(of: $0.folder, under: folder) })
            // Which languages the tree holds is decided after vendoring, over the vendored
            // packages too: a C target that arrives with a dependency — swift-cmark under
            // IceCubes — is compiled through clang like one of the tree's own, and a scan
            // before the copy could not see it (B-122). The vendored packages are not roots
            // and say nothing about the deployment version; they only add languages.
            let vendoredSummaries = try vendoredManifestFolders(in: dependencies).map(summarizeVendored)
            namespaces = GeneratedFiles.packageTreeNamespaces(
                forCFamilyTargets: GeneratedFiles.hasCFamilyTargets(in: summaries + vendoredSummaries))
            allSummaries = summaries + vendoredSummaries
        }

        // What each vendored package's copy is now, and what was left as it was (B-138).
        let standing = standingCopies(of: report.vendored)
        for copied in standing {
            switch copied.change {
            case .unchanged:
                report.unchanged.append(copied.name)
            case .copied(let reason):
                report.revendored.append(.init(name: copied.name, reason: reason, pin: copied.pin))
            }
        }
        let leftAsTheyWere = Set(standing.filter { $0.change == .unchanged }.map(\.destination.path))

        // Every package's binary targets in its `semel-artifacts`, before the locks are
        // taken over the copies that hold them (B-77): a `path:` zip unzipped here; what a
        // `url:` names was copied from resolution's download with its checkout. A copy left
        // as it was has its artifacts already, and its lock's root covers them.
        report.unzippedArtifacts = try unzipArtifacts(of: allSummaries.filter {
            !leftAsTheyWere.contains($0.folder.standardizedFileURL.path)
        })
        report.artifacts = artifactFolders(of: allSummaries)
        report.locks = try writeLocks(for: report.vendored, summaries: allSummaries)

        // A formula already there is kept, and it may select namespaces the one written
        // here would not — a hand-written app formula compiles catalogs. What it selects
        // joins the config, so the file is not the one thing prepare left it to write.
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

        func writeUnlessThere(_ contents: String, to file: URL) throws -> PrepareReport.FileOrigin {
            guard !FileManager.default.fileExists(atPath: file.path) else {
                report.kept.append(file)
                return .alreadyThere
            }
            try contents.write(to: file, atomically: true, encoding: .utf8)
            report.written.append(file)
            return .written
        }
        let formulaOrigin = try writeUnlessThere(formula, to: formulaFile)
        let configOrigin  = try writeUnlessThere(config, to: configFile)
        // Read back from the files the build reads, whichever wrote them.
        let converterSDK = projectFile == nil
            ? nil
            : try GeneratedFiles.converterSDK(inFormula: String(contentsOf: formulaFile, encoding: .utf8))
        report.buildsFor = .init(platform: platform, sdkVersion: sdkVersion,
                                 target: try GeneratedFiles.target(inProjectConfig: String(contentsOf: configFile, encoding: .utf8)),
                                 config: configOrigin,
                                 converterSDK: converterSDK.map { .init(sdk: $0, formula: formulaOrigin) })

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

    /// The platform a run is for when neither `--platform` nor a file already there names
    /// one.
    public static let defaultPlatform = Platform.macos

    /// What the files prepare never overwrites already say the build is for: the config's
    /// target, and for a project (`formula` non-nil) the formula's converter `sdk:`. A file
    /// that is not there, or states neither, holds nothing.
    static func heldPlatforms(config: URL, formula: URL?) throws -> [HeldPlatform] {
        var held: [HeldPlatform] = []
        if FileManager.default.fileExists(atPath: config.path),
           let target = GeneratedFiles.target(inProjectConfig: try String(contentsOf: config, encoding: .utf8)) {
            held.append(.init(file: config, setting: .target(target)))
        }
        if let formula, FileManager.default.fileExists(atPath: formula.path),
           let sdk = GeneratedFiles.converterSDK(inFormula: try String(contentsOf: formula, encoding: .utf8)) {
            held.append(.init(file: formula, setting: .converterSDK(sdk)))
        }
        return held
    }

    /// The run's platform: the one asked for, which every held setting must be for; else
    /// the one they are all for; else the default.
    static func platform(requested: Platform?, held: [HeldPlatform]) throws -> Platform {
        guard let requested else {
            guard !held.isEmpty else {
                return defaultPlatform
            }
            guard let kept = PlatformConflict.onePlatform(of: held) else {
                throw PlatformConflict.noOnePlatformHeld(held: held)
            }
            return kept
        }
        let disagreeing = held.filter { $0.platform != requested }
        guard disagreeing.isEmpty else {
            throw PlatformConflict.flagDisagrees(asked: requested, held: held, disagreeing: disagreeing)
        }
        return requested
    }

    /// A lock beside every copy made on this run, once every copy is in place (B-06):
    /// several roots vendor into one folder and a name two of them resolve is copied by the
    /// later one, so the lock is taken over the copy that stayed, with the pin of the root
    /// that copied it, and each binary target's checksum from the copy's manifest in
    /// `summaries` (B-77). A copy left as it was keeps its lock, byte for byte (B-138).
    static func writeLocks(for vendored: [Vendoring.Copied], summaries: [PackageSummary] = []) throws -> [URL] {
        try standingCopies(of: vendored).filter { $0.change != .unchanged }.map { copied in
            let destination = copied.destination.standardizedFileURL.path
            let summary = summaries.first { $0.folder.standardizedFileURL.path == destination }
            return try Vendoring.writeLock(for: copied, facts: summary.map(facts(of:)) ?? Vendoring.ManifestFacts())
        }
    }

    /// The entry that stood for each destination — the last, since a later copy replaces
    /// an earlier one — with its destination standardized, sorted by path.
    static func standingCopies(of vendored: [Vendoring.Copied]) -> [Vendoring.Copied] {
        var lastCopy: [String: Vendoring.Copied] = [:]
        for copied in vendored {
            let destination = copied.destination.standardizedFileURL
            lastCopy[destination.path] = Vendoring.Copied(name: copied.name, source: copied.source, destination: destination,
                                                          pin: copied.pin, change: copied.change)
        }
        return lastCopy.keys.sorted().compactMap { lastCopy[$0] }
    }

    /// What the package's lock records from its manifest: the `checksum:` of each of its
    /// binary targets that has one, by target (B-77), and the dot-named files its targets
    /// declare as resources (B-143).
    static func facts(of summary: PackageSummary) -> Vendoring.ManifestFacts {
        var checksums: [String: String] = [:]
        for binaryTarget in summary.binaryTargets {
            checksums[binaryTarget.name] = binaryTarget.checksum
        }
        return Vendoring.ManifestFacts(artifacts: checksums, hiddenFiles: hiddenResourceFiles(of: summary))
    }

    /// The dot-named files the package's targets declare as resources, relative to the
    /// package's folder: what its lock names (`DependencyLock.hiddenFiles`), so that its
    /// root covers them and a push of its folder sends them (B-143). A walk of the disk
    /// takes no dot-name, so without the lock naming them the build would read a resource
    /// the lock does not lock.
    ///
    /// Only a file, in no dot-named folder, as a push takes a dot-name: by its name, in a
    /// folder it walks. A declared dot-named folder cannot be pushed, and is not named
    /// here; the converter asks for it by its path, nobody can push it, and the build stops
    /// on it, naming it.
    static func hiddenResourceFiles(of summary: PackageSummary) -> [String] {
        let packagePath = summary.folder.standardizedFileURL.path
        let lister = ExternalFileSystemLister(rootDirectoryPath: packagePath)
        var found: Set<String> = []
        for target in summary.targets {
            for resource in target.resources {
                let full = target.folder.appendingPathComponent(resource).standardizedFileURL
                guard full.path.hasPrefix(packagePath + "/") else {
                    continue
                }
                let relative = String(full.path.dropFirst(packagePath.count + 1))
                guard DependencyLock.isHiddenFilePath(relative),
                      lister.hiddenFile(named: full.lastPathComponent,
                                        inDirectoryPath: full.deletingLastPathComponent().path) != nil else {
                    continue
                }
                found.insert(relative)
            }
        }
        return found.sorted()
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
    static func deploymentTarget(ofProjectAt project: URL, platform: Platform, application: String? = nil) throws -> String? {
        try XcodeProjectFacts.deploymentTarget(ofProjectAt: project, sdk: platform.sdkName, application: application)
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
