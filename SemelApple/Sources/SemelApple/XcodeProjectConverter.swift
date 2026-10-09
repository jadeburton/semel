//
//  XcodeProjectConverter.swift
//  SemelApple
//
//  Turns an Xcode project into formula text, the way `SwiftFormulaConverter` turns a
//  package manifest into one: a formula names the project —
//  `include XcodeProjectConverter(path: <IceCubesApp.xcodeproj>, root: <.>).formula` —
//  and the node wires what it needs itself: the project file, the xcconfig files it
//  names and the files they include, the trees of the folders that are the targets'
//  sources, read to every subfolder so the resources in them are known, and those of every
//  synchronized folder, whose folders directly in it are where Xcode finds local packages
//  the project file does not name (`LocalPackageSearch`). No tool runs; the project file is
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
    /// evaluated setting (B-77); at 7, an executable's linker takes each package product's
    /// link requirements (B-55); at 8, each package product's `frameworks_<Product>()` is
    /// compiled and linked against and embedded under the bundle's `Frameworks` (B-77); at
    /// 9, a target's C-family sources are compiled through clang and linked, its bridging
    /// header reaches its Swift compiler, and an Interface Builder document is compiled by
    /// ibtool rather than copied (B-77); at 10, a Mac bundle is assembled as one tree and
    /// signed ad-hoc by `CodeSigner` with its entitlements, and an asset catalog a target
    /// borrows is compiled for it (B-77); at 11, a synchronized folder's files are sorted
    /// by Xcode's rule — a plist, a Markdown file or an xcconfig copied, the target's own
    /// Info.plist and entitlements not — and a bundle or a folder the group names in
    /// `explicitFolders` is copied whole rather than walked (B-77); at 12, a target's Swift
    /// settings reach its compiler as a package's do — conditions as `defines`, features,
    /// `OTHER_SWIFT_FLAGS` and warnings as errors as `unsafeFlags` — `OTHER_CFLAGS` and a
    /// source's own flags reach clang, an application gets a `PkgInfo`, a copy-files
    /// phase's exception set copies its files there too, an exception naming a plain
    /// folder leaves out nothing under it, and a bundle whose settings ask for the hardened
    /// runtime is signed with it (B-77); at 13, the application built is the one whose
    /// `SDKROOT` is of the SDK's platform family, not the first, so NetNewsWire's simulator
    /// build is its iOS app (B-77); at 14, the targets' folders and the synchronized folders
    /// are asked for as trees, one wire each, where they were walked a level a pass (B-135);
    /// at 15, a package product is named once however many dependencies name it, one
    /// naming no package is a remote package's when another dependency names it with one,
    /// a product the frameworks phase lists is linked, a documentation catalog in a
    /// sources phase is passed over, and a copy to the products folder under a setting
    /// naming a folder of the bundle, `$(EXTENSIONS_FOLDER_PATH)`, is a copy into it, and a
    /// bundle is signed with the entitlements its sandbox and hardened-runtime settings
    /// stand for, and the `INFOPLIST_KEY_*` settings reach a plist only when it is
    /// generated (B-77); at 16, a project's own plist that is not generated keeps the
    /// identity and version it states, as Xcode's does, and a Mac bundle embeds its
    /// packages' resource bundles laid out as Mac bundles (B-77); at 17, a target's asset
    /// catalogs write its Swift asset symbols, which its compiler takes as
    /// `GeneratedAssetSymbols.swift`, and a bundle embeds each package product's
    /// `embedded_<Product>()` — its dynamic frameworks — where it embedded every framework
    /// (B-77 item 3, 10 and 12); at 18, a target that runs build-tool plugins and has no
    /// source of its own is the conversion's error, naming the target and its plugins, and
    /// every error the emitter names is the formula's, with the pass's demands, as the
    /// project's other errors are (B-77 item 3).
    /// 19: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    public static let implementationVersion = 19

    // MARK: Ports

    /// `project.pbxproj`, one wire.
    static let projectFile = "projectFile"
    /// The `.xcconfig` files the project and the targets name, and every file those
    /// include, keyed by path. One the clone does not have arrives without a value: an
    /// `#include?` then moves on, and anything else is read as empty and reported.
    static let xcconfigs = "xcconfigs"
    /// The subtree manifests of the targets' synchronized folders, and of every other
    /// synchronized folder of the project — the folders directly in which are where local
    /// packages are found — keyed by path (B-135).
    static let folders = "folders"
    static let formulaOutput = "formula"
    static let infoLog = "infoLog"

    /// Every config namespace the formula this converter emits may select from, for the
    /// targets it writes itself. The package formulas it includes select from
    /// `SwiftFormulaConverter`'s.
    public static let configNamespaces: [String] =
        configNamespaces(compilingCFamilySources: true, compilingInterfaceBuilderDocuments: true, signingBundles: true)

    /// The ones a project's formula selects from, by what its targets hold: the clang
    /// tools only for a target with C-family sources, ibtool only for one with a xib or
    /// a storyboard, codesign only for a platform whose bundles are signed — the Mac's
    /// (B-77). `prepare` writes a block for each of these and of the package formulas' and
    /// no other, because a block nothing reads is reported as unused keys on every build.
    public static func configNamespaces(compilingCFamilySources: Bool, compilingInterfaceBuilderDocuments: Bool,
                                        signingBundles: Bool) -> [String] {
        var namespaces = [
            XcodeFormulaEmitter.swiftCompilerNamespace,
            XcodeFormulaEmitter.swiftLinkerNamespace,
            AssetCatalogCompilerConfiguration.settingNamespace,
            StringCatalogCompilerConfiguration.settingNamespace,
        ]
        if compilingInterfaceBuilderDocuments {
            namespaces.append(IBToolCompilerConfiguration.settingNamespace)
        }
        if signingBundles {
            namespaces.append(CodeSignerConfiguration.settingNamespace)
        }
        if compilingCFamilySources {
            namespaces += [XcodeFormulaEmitter.clangPreprocessorNamespace, XcodeFormulaEmitter.clangCompilerNamespace]
        }
        return namespaces
    }

    /// Whether a build for `sdk` signs its bundles: the Mac's does, the simulator's does not.
    public static func signsBundles(forSDK sdk: String) -> Bool {
        XcodeFormulaEmitter.BundleLayout(sdk: sdk).isSigned
    }

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
                throw ErrorCondition.propertyMissing(type: "XcodeProjectConverter", property: "path", alternatives: [])
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
    /// The application target to build, by name, when more than one builds for `sdk`;
    /// otherwise the platform picks it (`XcodeProject.application(forSDK:named:settings:)`).
    var applicationName: String? { thisNode.properties["application"] }

    // MARK: Processing

    /// A conversion's failure belongs to the project it reads.
    public func errorSubject(input: ProcessInput?) -> ErrorDocument.Subject? {
        thisNode.properties["path"].map { .project(path: $0) }
    }

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
            return failed(.projectNotPushed(path: projectFilePath), specs: specs)
        case .value(let hash):
            projectHash = hash
        }
        guard let projectBytes = try DataObjectStore.shared.read(hash: projectHash) else {
            return failed(.projectHasNoContent(path: projectFilePath), specs: specs)
        }
        let project = try XcodeProject(pbxproj: Data(projectBytes))
        guard !project.applications.isEmpty else {
            return failed(.noApplicationTarget, specs: specs)
        }

        // ── the xcconfig files the project and the targets name, and theirs ──
        // Each file's includes are known only once it has arrived, so the files are
        // demanded a level at a time, the way a folder is walked. Every application's
        // first: its `SDKROOT` is what says which one this build is for, and only then are
        // the extensions it embeds known.
        let projectFolder = try projectFolder
        let xcconfigValues = input.inputValues[Self.xcconfigs] ?? [:]
        var expansions: [String: XcconfigExpansion] = [:]
        func expand(_ targets: [XcodeProject.Target]) throws {
            for root in project.xcconfigPaths(for: targets, configuration: configurationName) where expansions[root] == nil {
                let expansion = try XcconfigExpansion(root: root) { relativePath in
                    Self.xcconfigFile(at: Self.inputPath(of: relativePath, in: projectFolder), values: xcconfigValues)
                }
                expansions[root] = expansion
                for path in expansion.files.compactMap({ Self.inputPath(of: $0, in: projectFolder) }) {
                    specs[Self.xcconfigs]?[path] = .staticFile(at: path)
                }
            }
        }
        func evaluatedSettings(of target: XcodeProject.Target) throws -> XcodeBuildSettings {
            try XcodeBuildSettings.resolve(project: project, target: target, configuration: configurationName, sdk: sdk,
                                           xcconfig: { expansions[$0]?.assignments },
                                           extra: ["TARGET_NAME": target.name])
        }
        let application: XcodeProject.Target
        do {
            try expand(project.applications)
            if expansions.values.contains(where: \.isWaiting) {
                // Until the files are in, the one application there can be — the only one,
                // or the one named — is walked for already, so the waits overlap; its
                // platform is checked once they are in. Between several, nothing is walked.
                let provisional = applicationName.map { name in project.applications.first { $0.name == name } }
                    ?? (project.applications.count == 1 ? project.applications.first : nil)
                guard let provisional else {
                    return pending("waiting for the xcconfig files", specs: specs)
                }
                application = provisional
            } else {
                application = try project.application(forSDK: sdk, named: applicationName, settings: evaluatedSettings)
            }
            try expand(project.bundleTargets(of: application))
        } catch let failure as XcconfigExpansion.Failure {
            return failed(failure.errorCondition, specs: specs)
        } catch let failure as XcodeProjectError {
            return failed(failure.errorCondition, specs: specs)
        }
        let bundleTargets = project.bundleTargets(of: application)
        let embedded = Array(bundleTargets.dropFirst())

        // ── the target's folders, as trees ───────────────────────────────────
        // Demanded alongside the xcconfig files, so the two waits overlap, and each whole on
        // one wire, so however deep a folder goes it is in on the next pass (B-135).
        let trees = FolderTreeWalk.trees(in: input, port: Self.folders)
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
        var walkedRoots: [String] = []
        for folder in sourceFolders + borrowedWalks where !walkedRoots.contains(folder) {
            walkedRoots.append(folder)
            specs[Self.folders]?[folder] = .folderTree(at: folder)
        }
        // A folder the group names in `explicitFolders` is one item, copied whole.
        let explicitFolderPaths = Set(bundleTargets.flatMap(\.synchronizedFolders).flatMap { folder in
            folder.explicitFolders.map { "\(projectFolder)/\(folder.path)/\($0)" }
        })
        // Every group below the walked folders, read from their trees. A catalog is compiled
        // whole by its own node, and a folder copied whole by a `FolderTreeBuilder`, each
        // walking it itself; only a group is read here.
        var arrived: [String: FolderManifest] = [:]
        for root in walkedRoots {
            guard let tree = trees[root] else {
                continue
            }
            let reached = try tree.folderManifests(at: root) { subfolder in
                XcodeFormulaEmitter.folderRole(at: Path(subfolder).lastComponent ?? subfolder) == .group
                    && !explicitFolderPaths.contains(subfolder)
            }
            arrived.merge(reached) { existing, _ in existing }
        }

        // ── the local packages in the synchronized folders ──────────────────
        // On the same port: a folder a target owns is asked about by both and is one wire,
        // one tree, which answers for the folders directly in it as well. A folder that is
        // not there holds no package, where a target's missing folder is waited on; the
        // difference is that no target needs this one.
        var searched: [String: FolderManifest] = [:]
        for relativePath in project.synchronizedFolderPaths {
            guard let path = Self.inputPath(of: relativePath, in: projectFolder) else {
                continue
            }
            specs[Self.folders]?[path] = .folderTree(at: path)
            guard let tree = trees[path] else {
                continue
            }
            let reached = try tree.folderManifests(at: path) { subfolder in
                Path(subfolder).deletingLastComponent?.string == path
                    && !LocalPackageSearch.cannotBeAPackage(Path(subfolder).lastComponent ?? subfolder)
            }
            searched.merge(reached) { existing, _ in existing }
        }
        let packageSearch = LocalPackageSearch(project: project) { relativePath in
            guard let path = Self.inputPath(of: relativePath, in: projectFolder) else {
                return LocalPackageSearch.Contents()
            }
            return searched[path].map(LocalPackageSearch.Contents.init)
        }

        guard !expansions.values.contains(where: \.isWaiting) else {
            return pending("waiting for the xcconfig files", specs: specs)
        }
        guard walkedRoots.allSatisfy({ trees[$0] != nil }) else {
            return pending("waiting for the target's folders", specs: specs)
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
            return failed(.localPackagesNotFound(application: application.name, products: Set(localProducts).sorted(),
                                                 synchronizedFolders: project.synchronizedFolderPaths), specs: specs)
        }

        var listings: [String: XcodeFormulaEmitter.FolderListing] = [:]
        for sourceFolder in Set(sourceFolders + lendingFolders).sorted() {
            var listing = XcodeFormulaEmitter.FolderListing()
            for (folder, manifest) in arrived.sorted(by: { $0.key < $1.key })
                where folder == sourceFolder || folder.hasPrefix(sourceFolder + "/") {
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
        let formula: String
        do {
            formula = try emitter.formula(for: application, settings: evaluatedSettings, listing: { listings[$0] })
        } catch let failure as XcodeProjectError {
            return failed(failure.errorCondition, specs: specs)
        }
        if let notice = Self.pluginNotice(targets: bundleTargets) {
            NodeNotice.post(notice)
        }

        return .init(outputValues: [Self.formulaOutput: .value(try formula.intern()),
                                    Self.infoLog: try infoLogValue(application: application, embedded: embedded, project: project,
                                                                   projectFolder: projectFolder, expansions: expansions)],
                     inputWireSpecs: specs)
    }

    /// What the conversion says about the package plugins its targets run, which it does
    /// not; nil when none runs one. As a package's targets' plugins are named by the Swift
    /// converter: a plugin wants a design to run hermetically, and SwiftLint's — the one
    /// CodeEdit's app runs — writes nothing the build uses.
    static func pluginNotice(targets: [XcodeProject.Target]) -> String? {
        let named = targets.filter { !$0.plugins.isEmpty }.map { "\($0.plugins.joined(separator: ", ")) on \($0.name)" }
        guard !named.isEmpty else {
            return nil
        }
        return "Build-tool plugins are not run (B-77): \(named.joined(separator: "; ")). "
             + "Each target builds without what its plugins would do."
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

        return try ErrorDocument.engine(.xcconfigMissing(paths: missing, undefined: undefinedNames.sorted()),
                                        subject: errorSubject(input: nil)).published()
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

    private func failed(_ condition: ErrorCondition, specs: [String: [String: GraphSpecNode]]) -> ProcessOutput {
        let reason = (try? ErrorDocument.engine(condition, subject: errorSubject(input: nil)).asReason()) ?? .error(documentHash: "")
        return .init(outputValues: [Self.formulaOutput: .noValue(reason: reason),
                                    Self.infoLog: .noValue(reason: reason)],
                     inputWireSpecs: specs)
    }
}
