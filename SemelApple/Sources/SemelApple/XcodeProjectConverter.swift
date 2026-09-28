//
//  XcodeProjectConverter.swift
//  SemelApple
//
//  Turns an Xcode project into formula text, the way `SwiftFormulaConverter` turns a
//  package manifest into one: a formula names the project —
//  `include XcodeProjectConverter(path: <IceCubesApp.xcodeproj>, root: <.>).formula` —
//  and the node wires what it needs itself: the project file, the xcconfig files it
//  names and the files they include, the manifests of the folders that are the targets' sources, walked to
//  every subfolder so the resources in them are known, and those of every synchronized
//  folder and the folders directly in it, where Xcode finds local packages the project
//  file does not name (`LocalPackageSearch`). No tool runs; the project file is
//  a property list. `XcodeProject` reads it, `XcodeBuildSettings` evaluates it, and
//  `XcodeFormulaEmitter` writes the formula; this node owns the wires and the waiting.

import Foundation
import SemelDatabaseModels
import SemelNodeKit

public struct XcodeProjectConverter: Node {
    public static let kind: UInt = 34

    /// Emitted formula text changed for the same inputs: a target that lists its files,
    /// localized resources, and the package resource bundles in the app's tree (B-77); at 3,
    /// a target's literals are a `SettingsLiteral` under a `ConfigMerger` where they were a
    /// `Configuration`'s properties (B-120); at 4, xcconfig files are read the way Xcode
    /// layers them — includes demanded and followed, a configuration based on a file in a
    /// synchronized folder, an extension's own file, `config=` conditions (B-77); at 5, the
    /// synchronized folders are looked into for local packages, and every package found is
    /// included (B-77); at 6, `.lproj` folders are walked and their files placed under
    /// their language, a `/Localized/…` exception names a localized resource, a resources
    /// phase's folder reference is copied whole, and the Info.plist builder is handed every
    /// evaluated setting (B-77).
    public static let implementationVersion = 6

    // MARK: Ports

    /// `project.pbxproj`, one wire.
    static let projectFile = "projectFile"
    /// The `.xcconfig` files the project and the targets name, and every file those
    /// include, keyed by path. One the clone does not have arrives without a value: an
    /// `#include?` then moves on, and anything else is read as empty and reported.
    static let xcconfigs = "xcconfigs"
    /// The targets' synchronized folders and every folder under them, and every other
    /// synchronized folder of the project with the folders directly in it — where local
    /// packages are found — keyed by path.
    static let folders = "folders"
    static let formulaOutput = "formula"
    static let infoLog = "infoLog"

    /// The config namespaces the formula this converter emits selects from, for the
    /// targets it writes itself. The package formulas it includes select from
    /// `SwiftFormulaConverter`'s; `prepare` writes a block for each of both and no other,
    /// because a block nothing reads is reported as unused keys on every build.
    public static let configNamespaces: [String] = [
        XcodeFormulaEmitter.swiftCompilerNamespace,
        XcodeFormulaEmitter.swiftLinkerNamespace,
        AssetCatalogCompilerConfiguration.settingNamespace,
        StringCatalogCompilerConfiguration.settingNamespace,
    ]

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    /// Every port is dynamic: the node wires them from `path` itself, and a required port
    /// would have to be wired before the node exists.
    ///
    /// An xcconfig nobody pushed is a state the converter reads, not a failure of its
    /// wire: an `#include?` of a developer's own file (NetNewsWire's
    /// `../../SharedXcodeSettings/DeveloperSettings.xcconfig`, inside `input:` when the
    /// clone is pushed under a base above it) is expected to be absent, and so is the
    /// first of the two places a plain include is looked for when it is in the second.
    /// The converter names what is really missing — the root, a plain include found
    /// nowhere — as the cause of the settings it leaves undefined, on `infoLog`. The
    /// absent file is still demanded, not dropped once known absent: the wire is what a
    /// later push of it wakes the converter through.
    public static let descriptor = NodeDescriptor(
        inputPorts: [.dynamic(projectFile), .dynamic(xcconfigs), .dynamic(folders)],
        outputPorts: [formulaOutput, infoLog],
        inputPortsToleratingAbsentValue: [xcconfigs]
    )

    // MARK: Properties

    /// `input:/repo/IceCubesApp.xcodeproj`.
    var projectPath: String {
        get throws {
            guard let path = thisNode.properties["path"] else {
                throw NodeError.other(message: "XcodeProjectConverter needs a project: give it path: <X.xcodeproj>")
            }
            return path
        }
    }

    /// The folder holding the project, which its paths are relative to.
    var projectFolder: String {
        get throws { (Path(try projectPath).deletingLastComponent ?? Path("")).string }
    }

    /// Where `semel.config` and `Dependencies/` live: `root` when the formula gives one,
    /// else the project's folder.
    var buildRoot: String {
        get throws {
            if let root = thisNode.properties["root"] {
                return root
            }
            return try projectFolder
        }
    }

    var configurationName: String { thisNode.properties["configuration"] ?? "Debug" }
    var sdk: String { thisNode.properties["sdk"] ?? "iphonesimulator" }

    // MARK: Processing

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let projectFilePath = "\(try projectPath)/project.pbxproj"
        var specs: [String: [String: GraphSpecNode]] = [
            Self.projectFile: [projectFilePath: .staticFile(at: projectFilePath)],
            Self.xcconfigs: [:],
            Self.folders: [:],
        ]

        // ── the project file, a pass later than the node's creation ─────────
        guard let projectValue = input.inputValues[Self.projectFile]?[projectFilePath] else {
            return pending("waiting for \(projectFilePath)", specs: specs)
        }
        let projectHash: DataObjectHash
        switch projectValue {
        case .noValue(.pending):
            return pending("waiting for \(projectFilePath)", specs: specs)
        case .noValue(.initializing), .noValue(.inputNotProduced),
             .noValue(.inputInError), .noValue(.deleted), .noValue(.error):
            // A file node that has never been processed is a file nobody pushed: a
            // `StaticFile` with no inputs has nothing to wait for, so this is as far as it
            // goes, and a file that was removed leaves the same hole. The remedy is the one
            // a missing file gets.
            return failed("\(projectFilePath) is not in the input file system; push the project's folder", specs: specs)
        case .value(let hash):
            projectHash = hash
        }
        guard let projectBytes = try DataObjectStore.shared.read(hash: projectHash) else {
            return failed("\(projectFilePath) has no content", specs: specs)
        }
        let project = try XcodeProject(pbxproj: Data(projectBytes))
        guard let application = project.targets.first(where: \.isApplication) else {
            return failed("the project has no application target", specs: specs)
        }

        // ── the xcconfig files the project and the targets name, and theirs ──
        // Each file's includes are known only once it has arrived, so the files are
        // demanded a level at a time, the way a folder is walked.
        let projectFolder = try projectFolder
        let bundleTargets = project.bundleTargets(of: application)
        let embedded = Array(bundleTargets.dropFirst())
        let xcconfigValues = input.inputValues[Self.xcconfigs] ?? [:]
        var expansions: [String: XcconfigExpansion] = [:]
        for root in project.xcconfigPaths(for: bundleTargets, configuration: configurationName) {
            let expansion: XcconfigExpansion
            do {
                expansion = try XcconfigExpansion(root: root) { relativePath in
                    Self.xcconfigFile(at: Self.inputPath(of: relativePath, in: projectFolder), values: xcconfigValues)
                }
            } catch let failure as XcconfigExpansion.Failure {
                return failed(failure.description, specs: specs)
            }
            expansions[root] = expansion
            for path in expansion.files.compactMap({ Self.inputPath(of: $0, in: projectFolder) }) {
                specs[Self.xcconfigs]?[path] = .staticFile(at: path)
            }
        }

        // ── the target's folders, walked ─────────────────────────────────────
        // Demanded alongside the xcconfig files, so the two waits overlap.
        let manifests = FolderTreeWalk.manifests(in: input, port: Self.folders)
        let arrived = Dictionary(uniqueKeysWithValues: manifests.map { ($0.key, $0.manifest) })
        // The application's folders and every embedded extension's: each is a bundle
        // whose resources come from its own folder. A localized resource one of them
        // borrows (`/Localized/ShareExtension/…`) is found by walking the folder in the
        // lending folder that holds its language folders, and listed with the lender.
        let sourceFolders = bundleTargets.flatMap(\.synchronizedFolders).map { "\(projectFolder)/\($0.path)" }
        let borrowedLocalized = bundleTargets.flatMap(\.borrowedLocalizedResources)
        let lendingFolders = borrowedLocalized.map { "\(projectFolder)/\($0.folder)" }
        let borrowedWalks = borrowedLocalized.compactMap { borrowed -> String? in
            guard case .localized(let folder, _) = borrowed.exception else {
                return nil
            }
            return folder.isEmpty ? "\(projectFolder)/\(borrowed.folder)" : "\(projectFolder)/\(borrowed.folder)/\(folder)"
        }
        var demanded: [String] = []
        var seen = Set<String>()
        func demand(_ folder: String) {
            if seen.insert(folder).inserted {
                demanded.append(folder)
            }
        }
        (sourceFolders + borrowedWalks).forEach(demand)
        var index = 0
        while index < demanded.count {
            let folder = demanded[index]
            index += 1
            specs[Self.folders]?[folder] = .folderManifest(at: folder)
            guard let manifest = arrived[folder] else {
                continue
            }
            // A catalog is compiled whole by its own node, which walks it itself.
            for entry in manifest.entries where entry.isFolder && entry.isPinned && !Self.isCompiledWhole(entry.name) {
                demand("\(folder)/\(entry.name)")
            }
        }

        // ── the local packages in the synchronized folders ──────────────────
        // On the same port: a folder a target owns is asked about by both walks and is
        // one wire. A folder that is not there holds no package, where a target's missing
        // folder is waited on; the difference is that no target needs this one.
        let folderValues = input.inputValues[Self.folders] ?? [:]
        let packageSearch = LocalPackageSearch(project: project) { relativePath in
            guard let path = Self.inputPath(of: relativePath, in: projectFolder) else {
                return LocalPackageSearch.Contents()
            }
            if let manifest = arrived[path] {
                return LocalPackageSearch.Contents(manifest)
            }
            switch folderValues[path] {
            case nil, .noValue(.pending):
                return nil
            case .value, .noValue:
                return LocalPackageSearch.Contents()
            }
        }
        for path in packageSearch.asked.compactMap({ Self.inputPath(of: $0, in: projectFolder) }) {
            specs[Self.folders]?[path] = .folderManifest(at: path)
        }

        guard !expansions.values.contains(where: \.isWaiting) else {
            return pending("waiting for the xcconfig files", specs: specs)
        }
        guard demanded.allSatisfy({ arrived[$0] != nil }) else {
            return pending("walking the target's folders", specs: specs)
        }
        guard packageSearch.isComplete else {
            return pending("looking for local packages in the synchronized folders", specs: specs)
        }
        let localProducts = bundleTargets.flatMap(\.packageProducts).compactMap { product -> String? in
            guard case .local(let name) = product else {
                return nil
            }
            return name
        }
        guard localProducts.isEmpty || !packageSearch.packagePaths.isEmpty else {
            let folders = project.synchronizedFolderPaths.isEmpty ? "none" : project.synchronizedFolderPaths.joined(separator: ", ")
            return failed("\(application.name) links \(Set(localProducts).sorted().joined(separator: ", ")) from local packages, "
                          + "and the project has none: it declares no package folder, and no folder directly in a synchronized "
                          + "folder (\(folders)) holds a \(LocalPackageSearch.manifestName)", specs: specs)
        }

        var listings: [String: XcodeFormulaEmitter.FolderListing] = [:]
        for sourceFolder in Set(sourceFolders + lendingFolders).sorted() {
            var listing = XcodeFormulaEmitter.FolderListing()
            for folder in demanded where folder == sourceFolder || folder.hasPrefix(sourceFolder + "/") {
                guard let manifest = arrived[folder] else { continue }
                let prefix = folder == sourceFolder ? "" : String(folder.dropFirst(sourceFolder.count + 1)) + "/"
                for entry in manifest.entries where entry.isPinned {
                    if entry.isFolder {
                        listing.folders.append(prefix + entry.name)
                    } else {
                        listing.files.append(prefix + entry.name)
                    }
                }
            }
            listings[sourceFolder] = listing
        }

        // ── the formula ──────────────────────────────────────────────────────
        let build = XcodeFormulaEmitter.Build(root: try buildRoot, projectFolder: projectFolder,
                                              configuration: configurationName, sdk: sdk)
        let emitter = XcodeFormulaEmitter(project: project, build: build, localPackagePaths: packageSearch.packagePaths)
        let formula = try emitter.formula(
            settings: { target in
                try XcodeBuildSettings.resolve(project: project, target: target, configuration: self.configurationName, sdk: self.sdk,
                                               xcconfig: { expansions[$0]?.assignments },
                                               extra: ["TARGET_NAME": target.name])
            },
            listing: { listings[$0] })

        return .init(outputValues: [Self.formulaOutput: .value(try formula.intern()),
                                    Self.infoLog: try infoLogValue(application: application, embedded: embedded, project: project,
                                                                   projectFolder: projectFolder, expansions: expansions)],
                     inputWireSpecs: specs)
    }

    /// A path relative to the project's folder as a path in the input file system; nil
    /// for one outside it — absolute, or climbing above `input:` — which no push can have
    /// filled, so it is not there without being asked for.
    static func inputPath(of relativePath: String, in projectFolder: String) -> String? {
        guard !relativePath.hasPrefix("/") else {
            return nil
        }
        return Path("\(projectFolder)/\(relativePath)").resolvingDotSegments?.string
    }

    /// What has arrived for one xcconfig file. A wire with no answer yet, or a pending one,
    /// is waited on; any other absence of a value is a file nobody pushed.
    static func xcconfigFile(at path: String?, values: [String: NodeValue]) -> XcconfigFile {
        guard let path else {
            return .absent
        }
        switch values[path] {
        case nil, .noValue(.pending):
            return .pending
        case .value(let hash):
            guard let text = try? hash.resolveAsString() else {
                return .absent
            }
            return .present(Xcconfig(parsing: text))
        case .noValue:
            return .absent
        }
    }

    /// The success message, or — once an xcconfig the project names, or one a plain
    /// `#include` names, has no value — the cause: which file is missing and which
    /// settings it would have defined. Reported as
    /// an error only when that set is not empty; a missing file nothing referenced is not
    /// a broken build, so it is folded into the ordinary success message instead. An error
    /// here, not just the info it replaces, is what lets a real cause reach the idle error
    /// report; `formulaOutput` still carries the formula, since one port's error does not
    /// stop another port on the same node from carrying its value. The settings are
    /// resolved again over the application and its extensions — the same evaluation
    /// `XcodeFormulaEmitter` already ran per target — so the message names exactly what the
    /// missing file would have to define.
    private func infoLogValue(application: XcodeProject.Target, embedded: [XcodeProject.Target], project: XcodeProject,
                              projectFolder: String, expansions: [String: XcconfigExpansion]) throws -> NodeValue {
        let converted = "converted \(application.name) for \(sdk), \(configurationName)"
        var missing: [String] = []
        for relativePath in expansions.keys.sorted().flatMap({ expansions[$0]?.missing ?? [] }) {
            let path = Self.inputPath(of: relativePath, in: projectFolder) ?? relativePath
            if !missing.contains(path) {
                missing.append(path)
            }
        }
        guard !missing.isEmpty else {
            return .value(try converted.intern())
        }

        var undefinedNames = Set<String>()
        for target in [application] + embedded {
            let settings = try XcodeBuildSettings.resolve(project: project, target: target, configuration: configurationName, sdk: sdk,
                                                           xcconfig: { expansions[$0]?.assignments },
                                                           extra: ["TARGET_NAME": target.name])
            undefinedNames.formUnion(settings.unresolvedReferences)
        }

        guard !undefinedNames.isEmpty else {
            let lines = ([converted] + missing.map { "xcconfig \($0) is missing; nothing referenced it" }).joined(separator: "\n")
            return .value(try lines.intern())
        }

        let names = undefinedNames.sorted().joined(separator: ", ")
        let message = missing
            .map { "xcconfig \($0) is missing; settings it would define are undefined (\(names))" }
            .joined(separator: "\n")
        return .noValue(reason: .error(messageDataObjectHash: try message.intern()))
    }

    /// Folders whose contents are one compiled unit: never walked, so their files are not
    /// mistaken for resources of their own. A `.lproj` is walked: its files are
    /// resources, each placed under its language folder.
    static func isCompiledWhole(_ folderName: String) -> Bool {
        folderName.hasSuffix(".xcassets") || folderName.hasSuffix(".icon") || folderName.hasSuffix(".xcdatamodeld")
    }

    private func pending(_ reason: String, specs: [String: [String: GraphSpecNode]]) -> ProcessOutput {
        .init(outputValues: [Self.formulaOutput: .noValue(reason: .pending),
                             Self.infoLog: .noValue(reason: .pending)],
              inputWireSpecs: specs)
    }

    private func failed(_ message: String, specs: [String: [String: GraphSpecNode]]) -> ProcessOutput {
        let reason = NoValueReason.error(messageDataObjectHash: (try? "XcodeProjectConverter: \(message)".intern()) ?? "")
        return .init(outputValues: [Self.formulaOutput: .noValue(reason: reason),
                                    Self.infoLog: .noValue(reason: reason)],
                     inputWireSpecs: specs)
    }
}
