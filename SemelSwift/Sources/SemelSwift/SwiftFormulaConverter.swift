// SwiftFormulaConverter.swift
// SemelCore
//
// Converts a `swift package dump-package` JSON manifest into a .fmla formula
// string that ProjectBuilder can consume as its projectFile input.
//
// Wire topology:
//   Folder(path: 'input:/.../MyPkg').manifest -> SwiftFormulaConverter.packageFolder
//   SwiftPackageReader.packageJSON                 -> SwiftFormulaConverter.packageJSON
//   SwiftFormulaConverter.formula                      -> ProjectBuilder.projectFile
//
// `packageFolder` is wired to a Folder.manifest rather than stored as a
// property so the node re-runs whenever files are added to or removed from the
// package root (e.g. a new Sources/NewTarget directory appears). The package
// path is read from FolderManifest.baseFolderPath at process time.
//
// External package dependencies are resolved iteratively via the dynamic
// `externalPackageJSONs` port.  After parsing the root Package.swift the node
// returns SwiftPackageReader wire specs for each fileSystem dep it
// finds; when those manifests arrive the process repeats for their own deps,
// and so on until the full transitive closure is wired.  Packages no longer
// referenced are automatically unwired by applySpecs.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

struct SwiftFormulaConverter: Node {
    public static let kind: UInt = 24

    static let packageFolder        = "packageFolder"
    static let packageJSON          = "packageJSON"
    static let formulaOutput        = "formula"
    static let infoLog              = "infoLog"
    static let externalPackageJSONs = "externalPackageJSONs"
    /// The folder manifest of every compilable target, root and dependencies alike, keyed
    /// by folder path. A manifest says nothing about a target's language; the folder does:
    /// C sources and no Swift make it a C target (B-54), built through the clang nodes.
    static let targetFolders        = "targetFolders"
    /// Every folder under a compilable target's folder that is not a resource whole,
    /// keyed by path: what says which resources a target carries — a catalog at its top,
    /// `Resources/en.lproj` two levels down (B-77). Walked level by level once the
    /// target folders are in.
    static let targetSubfolders     = "targetSubfolders"
    /// The folder of every dependency package whose manifest has not arrived, keyed by
    /// path, wired for as long as the converter waits for it. The value is never read: the
    /// wire is how the stall names what it waits for, typed. A folder nobody has pushed
    /// that a node needs is a source the settle reports by path, so `build` pushes the
    /// whole package in one round rather than the reader's `Package.swift` and then each
    /// target folder, a settle apiece (B-110).
    static let awaitedPackageFolders = "awaitedPackageFolders"
    /// The lock beside every package read from the root's `Dependencies` folder, keyed by
    /// the lock's path, and the content root of each whose lock is there, keyed by the
    /// package's folder (B-06, `DependencyLockCheck`).
    static let dependencyLocks        = "dependencyLocks"
    static let dependencyContentRoots = "dependencyContentRoots"
    /// The Swift linker's settings, the root's config as the product's linker reads it,
    /// asked for only when a manifest has a linker setting conditional on a platform: its
    /// `sdk` is the platform being built, which says whether the setting holds (B-55).
    static let linkerConfiguration    = "linkerConfiguration"
    /// The folders a binary target's `.xcframework` is found through, keyed by path (B-77):
    /// a `path:` one's own folder, or for a downloaded or zipped one the package folder,
    /// its `semel-artifacts` and the target's folder in that, each asked for only once the
    /// one above lists it — a folder asked for under a vendored package that is not there
    /// would be a ghost its content root folds, failing the lock (B-133).
    static let binaryArtifactFolders  = "binaryArtifactFolders"

    /// The folder in a package where `semel-swift prepare` puts a binary target's artifact,
    /// one folder per target.
    static let artifactsFolderName    = DependencyLock.artifactsFolderName

    /// The clang nodes a C target is built through. Named rather than imported: this
    /// package does not depend on SemelClang, and a formula names a node by type name.
    static let clangPreprocessorNamespace = derivedSettingNamespace(forTypeName: "ClangPreprocessor")
    static let clangCompilerNamespace     = derivedSettingNamespace(forTypeName: "ClangCompiler")

    /// The Apple nodes a target's resources are built through, named the same way; the
    /// Apple package pins its namespaces under `apple.` rather than deriving them, so the
    /// names are spelled here and `SemelApple`'s tests hold them to these (B-77).
    static let assetCatalogCompilerNamespace  = "apple.assetCatalogCompiler"
    static let stringCatalogCompilerNamespace = "apple.stringCatalogCompiler"

    /// Emitted formula text changed for the same inputs: every product gained a
    /// `bundles_<Product>()` func and a target with resources a bundle (B-77); at 3, a
    /// target's literals are a `SettingsLiteral` under a `ConfigMerger` where they were a
    /// `Configuration`'s properties, in the formula and in the reader it demands (B-120);
    /// at 4, a C target's sources are one `**` for-each with its exclusions as `except`,
    /// and its public headers follow `publicHeadersPath` (B-55); at 5, a stall demands the
    /// folder of each package it waits for (B-110); at 6, it demands the lock and the
    /// content root of every vendored package, and a mismatch is its error (B-06); at 7, a
    /// declared resource's dot segments are resolved (B-125); at 8, a target at its
    /// package's root demands the package folder by its own name, and a C target's
    /// `.headerSearchPath` folders are header folders and its resources a bundle (B-134);
    /// at 9, a binary target is named as not built rather than compiled, and the target
    /// folders are demanded before the lock is compared, on every pass whatever it says
    /// (B-133); at 10, every product has a `linking_<Product>()` func of its link
    /// requirements, wired to its own linker when it has any, a C target's assembly is
    /// compiled, and the linker's settings are demanded when a linker setting is
    /// conditional on a platform (B-55); at 11, a C target reaches Swift as a header tree on
    /// `moduleTrees` with the module map SwiftPM would write when it has none, and a C
    /// target with Objective-C is preprocessed and compiled with modules and ARC (B-55, B-77);
    /// at 12, a binary target's `.xcframework` is found through `binaryArtifactFolders`,
    /// its slice chosen by an `XCFrameworkSliceSelector`, and every product has a
    /// `frameworks_<Product>()` func, a product vending only binary targets its funcs and
    /// no linker (B-77).
    public static let implementationVersion = 12

    /// The config namespaces a formula this converter emits selects from. `prepare`
    /// writes a block for each of these and no other, because a block nothing reads is
    /// reported as unused keys on every build. A package's objects go into an archive
    /// or the Swift linker's product, so `clang.linker` is not among them.
    static let configNamespaces: [String] = swiftConfigNamespaces + clangConfigNamespaces

    /// What every package's formula selects from.
    static let swiftConfigNamespaces: [String] = [
        SwiftPackageReaderConfiguration.settingNamespace,
        SwiftCompilerConfiguration.settingNamespace,
        SwiftLinkerConfiguration.settingNamespace,
    ]

    /// What a formula selects from only when the tree has a C-family target (B-110): a
    /// block for a tool nothing runs is reported as unused keys on every build.
    static let clangConfigNamespaces: [String] = [clangPreprocessorNamespace, clangCompilerNamespace]

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    // packageFolder and packageJSON are dynamic rather than required because the node
    // wires them itself when a formula names the package by path —
    // `include SwiftFormulaConverter(path: <.>).formula` — and a required port has to be
    // wired before the node exists. Wired explicitly, the older form, they work the same.
    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .dynamic(packageFolder),
            .dynamic(packageJSON),
            .dynamic(externalPackageJSONs),
            .dynamic(targetFolders),
            .dynamic(targetSubfolders),
            .dynamic(awaitedPackageFolders),
            .dynamic(dependencyLocks),
            .dynamic(dependencyContentRoots),
            .dynamic(linkerConfiguration),
            .dynamic(binaryArtifactFolders),
        ],
        outputPorts: [formulaOutput, infoLog],
        // A lock nobody wrote is a state the converter reads — it says so in a notice and
        // builds — so the report does not name the unpushed file as a failure.
        inputPortsToleratingAbsentValue: [dependencyLocks]
    )

    /// The wires a `path` property stands for: the package folder's manifest, and a reader
    /// over its `Package.swift` that selects its settings from the config beside the
    /// package. Empty when the node was wired explicitly instead.
    ///
    /// The reader shells out to a toolchain, so it needs the same `toolDescriptor` settings
    /// every other tool does. This is the first node of every Swift build: wired to an
    /// empty `SettingsLiteral()` it fails before the manifest is ever read.
    private var selfWiringSpecs: [String: [String: GraphSpecNode]] {
        guard let packageFolder = thisNode.properties["path"] else {
            return [:]
        }
        let manifestPath = "\(packageFolder)/Package.swift"
        return [
            Self.packageFolder: [packageFolder: .folderManifest(at: packageFolder)],
            Self.packageJSON:   [manifestPath: Self.packageReaderSpec(packageFilePath: manifestPath,
                                                                     rootPackageFolder: buildRoot(defaultingTo: packageFolder))],
        ]
    }

    /// Where the build's config file and vendored dependencies live: the `root` property
    /// when a formula gives one — `SwiftFormulaConverter(path: <Timeline>, root: <.>)` —
    /// otherwise the package's own folder. Several packages included by one formula share
    /// one `Dependencies` folder and one `semel.config` this way, instead of vendoring and
    /// compiling their common closure once per package (B-56). Sources are never affected:
    /// a target's files are under its package whatever the root.
    private func buildRoot(defaultingTo packageFolder: String) -> String {
        thisNode.properties["root"] ?? packageFolder
    }

    // MARK: - Processing

    public func process(input: ProcessInput) throws -> ProcessOutput {

        // ── which package ─────────────────────────────────────────────────────
        // Named by `path`, in which case the folder manifest and the manifest reader are
        // this node's own wires and arrive a pass later; or wired explicitly.
        guard let folderValue = input.inputValues[Self.packageFolder]?.values.first,
              let jsonValue   = input.inputValues[Self.packageJSON]?.values.first else {
            guard !selfWiringSpecs.isEmpty else {
                throw NodeError.other(message: "SwiftFormulaConverter needs a package: give it path: <folder>, "
                                             + "or wire packageFolder and packageJSON")
            }
            return try pendingOutput(reason: "SwiftFormulaConverter: waiting for the package folder and manifest")
        }

        // ── packageFolder ─────────────────────────────────────────────────────
        let manifestJSON = try folderValue.expectValue().resolveAsString()

        guard let folderManifest = try? TypeRegistry.decode(encodedJSON: manifestJSON) as? FolderManifest else {
            return try pendingOutput(reason: "SwiftFormulaConverter: could not decode FolderManifest")
        }

        let rootPackageFolder = folderManifest.baseFolderPath

        // ── root packageJSON ──────────────────────────────────────────────────
        let jsonEntry = try jsonValue.expectValue()

        let rootManifest: SPMManifest

        do {
            rootManifest = try SPMManifest.decode(try jsonEntry.resolveAsString())
        } catch {
            return try pendingOutput(reason: "SwiftFormulaConverter: \(error)")
        }

        // ── already-received external manifests ───────────────────────────────
        // Wire key = resolved input-filesystem path of the external package root.
        var availableManifests: [String: SPMManifest] = [:]

        for (extPath, nodeValue) in input.inputValues[Self.externalPackageJSONs] ?? [:] {

            guard let jsonStr  = try? nodeValue.expectValue().resolveAsString(),
                  let manifest = try? SPMManifest.decode(jsonStr) else {
                continue
            }

            availableManifests[extPath] = manifest
        }

        // ── BFS: discover all transitively needed external packages ───────────
        // Each run reaches one more nesting level; missing manifests are requested
        // via wire specs and the node is re-scheduled when they arrive.
        var bfsQueue: [(path: String, manifest: SPMManifest)] = [(rootPackageFolder, rootManifest)]
        var visitedPaths = Set<String>([rootPackageFolder])
        var specs: [String: GraphSpecNode] = [:]
        // Path -> the repository URL or registry package it stands for, nil when the
        // manifest named the path itself. Only ever read to explain a stall.
        var originOfExpectedPath: [String: String?] = [:]
        var bfsIndex = 0

        while bfsIndex < bfsQueue.count {
            let (manifestPath, manifest) = bfsQueue[bfsIndex]; bfsIndex += 1

            for dependency in manifest.referencedDependencies() {
                // A local path is relative to the manifest that declared it, which may
                // itself be a dependency several levels down. A vendored package is under
                // the root's Dependencies folder whoever declared it: one copy per package.
                let extPath = dependency.resolvedPath(declaringPackage: manifestPath,
                                                      root: buildRoot(defaultingTo: rootPackageFolder),
                                                      resolve: resolveRelativePath)
                // Skip dependencies whose resolved path falls outside the virtual
                // inputFileSystem — they are system-level or truly external packages
                // that cannot be read through the build graph.
                guard extPath.hasPrefix(FileSystemName.input + "/") else {
                    continue
                }

                guard !visitedPaths.contains(extPath) else {
                    continue
                }

                visitedPaths.insert(extPath)
                // The root package's folder, not `extPath`: the reader that parses a vendored
                // dependency's manifest is still part of *this* build, so it selects its
                // settings from the config file the consuming project owns.
                specs[extPath] = Self.packageReaderSpec(
                    packageFilePath: "\(extPath)/Package.swift",
                    rootPackageFolder: buildRoot(defaultingTo: rootPackageFolder))
                originOfExpectedPath[extPath] = dependency.origin

                if let extManifest = availableManifests[extPath] {
                    bfsQueue.append((extPath, extManifest))
                }
            }
        }

        // ── the lock beside every vendored package (B-06) ────────────────────
        // Asked for alongside the manifests, so the locks arrive while they do.
        let lockCheck = DependencyLockCheck(
            packageFolders: [rootPackageFolder] + Array(specs.keys),
            dependenciesFolder: "\(buildRoot(defaultingTo: rootPackageFolder))/\(Self.dependenciesFolderName)")
        let lockValues = input.inputValues[Self.dependencyLocks] ?? [:]
        var demands = Demands(packageManifests: specs,
                              locks: lockCheck.lockSpecs,
                              contentRoots: lockCheck.contentRootSpecs(locks: lockValues))

        // ── wait until every expected manifest has been received ──────────────
        let missing = specs.keys.filter { availableManifests[$0] == nil }

        guard missing.isEmpty else {
            demands.awaitedPackageFolders = Dictionary(uniqueKeysWithValues: missing.map { ($0, .folderManifest(at: $0)) })
            return try pendingOutput(reason: describeStall(missingPaths: missing.sorted(), origins: originOfExpectedPath),
                                     demands: demands)
        }

        // ── the platform, when a linker setting depends on it (B-55) ─────────
        // Asked for with the target folders, so it arrives while they do.
        let everyManifest = [rootManifest] + availableManifests.sorted(by: { $0.key < $1.key }).map(\.value)
        let asksForPlatform = everyManifest.contains { manifest in
            manifest.targets.contains(where: \.hasPlatformConditionalLinkerSetting)
        }
        if asksForPlatform {
            demands.linkerConfiguration = [
                SwiftLinkerConfiguration.settingNamespace: Self.configurationTree(
                    namespace: SwiftLinkerConfiguration.settingNamespace,
                    packageFolder: buildRoot(defaultingTo: rootPackageFolder),
                    literals: [:]),
            ]
        }

        // ── every compilable target's folder, to tell C targets from Swift ones ──
        // A manifest says nothing about a target's language; its folder does. The
        // folders are asked for once every manifest is in, so this is one more pass.
        var targetFolderSpecs: [String: GraphSpecNode] = [:]
        for (packageFolder, manifest) in [(rootPackageFolder, rootManifest)] + availableManifests.sorted(by: { $0.key < $1.key }) {
            for target in manifest.targets where target.isCompilable {
                let folder = target.folder(in: packageFolder)
                targetFolderSpecs[folder] = .folderManifest(at: folder)
            }
        }
        demands.targetFolders = targetFolderSpecs

        // ── every binary target's .xcframework (B-77) ─────────────────────────
        // Asked for with the target folders, one level a pass, only as far as what has
        // arrived lists.
        let binaryWalk = BinaryArtifactWalk(
            packages: [(rootPackageFolder, rootManifest)] + availableManifests.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) },
            rootFolderManifest: folderManifest,
            arrived: Dictionary(FolderTreeWalk.manifests(in: input, port: Self.binaryArtifactFolders).map { ($0.key, $0.manifest) },
                                uniquingKeysWith: { first, _ in first }))
        demands.binaryArtifactFolders = binaryWalk.specs

        var targetFolderManifests: [String: FolderManifest] = [:]
        for (folder, nodeValue) in input.inputValues[Self.targetFolders] ?? [:] {
            guard let json = try? nodeValue.expectValue().resolveAsString(),
                  let manifest = try? TypeRegistry.decode(encodedJSON: json) as? FolderManifest else {
                continue
            }
            targetFolderManifests[folder] = manifest
        }

        let missingFolders = targetFolderSpecs.keys.filter { targetFolderManifests[$0] == nil }.sorted()
        guard missingFolders.isEmpty else {
            return try pendingOutput(
                reason: "SwiftFormulaConverter: waiting for \(missingFolders.count) target folder(s):\n"
                      + missingFolders.map { "  \($0)" }.joined(separator: "\n"),
                demands: demands)
        }
        guard binaryWalk.waiting.isEmpty else {
            return try pendingOutput(
                reason: "SwiftFormulaConverter: walking \(binaryWalk.waiting.count) folder(s) for binary targets' artifacts:\n"
                      + binaryWalk.waiting.map { "  \($0)" }.joined(separator: "\n"),
                demands: demands)
        }

        // ── every target folder's subfolders, for the resources a target carries (B-77) ──
        // Level by level, one pass each; a folder that is a resource whole — a catalog,
        // an `.lproj` — is named and not entered. The compiler walks these same folders
        // for its sources, so the folder nodes exist already; this adds wires to them.
        var folderManifests = targetFolderManifests
        for (folder, nodeValue) in (input.inputValues[Self.targetSubfolders] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let json = try? nodeValue.expectValue().resolveAsString(),
                  let manifest = try? TypeRegistry.decode(encodedJSON: json) as? FolderManifest else {
                continue
            }
            folderManifests[folder] = manifest
        }
        var subfolderSpecs: [String: GraphSpecNode] = [:]
        var walked = targetFolderSpecs.keys.sorted()
        var walkIndex = 0
        while walkIndex < walked.count {
            let folder = walked[walkIndex]
            walkIndex += 1
            guard let manifest = folderManifests[folder] else {
                continue
            }
            for entry in manifest.entries where entry.isFolder && entry.isPinned && PackageResources.isWalked(folderName: entry.name) {
                let subfolder = "\(folder)/\(entry.name)"
                subfolderSpecs[subfolder] = .folderManifest(at: subfolder)
                walked.append(subfolder)
            }
        }
        demands.targetSubfolders = subfolderSpecs
        let missingSubfolders = subfolderSpecs.keys.filter { folderManifests[$0] == nil }.sorted()
        guard missingSubfolders.isEmpty else {
            return try pendingOutput(
                reason: "SwiftFormulaConverter: walking \(missingSubfolders.count) target subfolder(s) for resources",
                demands: demands)
        }

        // The platform is the SDK the product's linker links against, by its own default
        // when the settings name none.
        var platform: String?
        if asksForPlatform {
            guard let settingsValue = input.inputValues[Self.linkerConfiguration]?.values.first,
                  let settingsText = try? settingsValue.expectValue().resolveAsString() else {
                return try pendingOutput(
                    reason: "SwiftFormulaConverter: waiting for the \(SwiftLinkerConfiguration.settingNamespace) settings, "
                          + "whose sdk is the platform a linker setting's .when(platforms:) is decided for",
                    demands: demands)
            }
            let settings = [String: String](plainText: settingsText)
            platform = Self.swiftPMPlatformName(forSDK: settings["sdk"] ?? defaultSDKName)
        }

        // ── every lock compared with its package's content root ───────────────
        // Last of the waits, once every folder has been asked for. A demand is a node, and a
        // path demanded under a vendored package that is not there is a ghost the package's
        // content root folds; were the demands to hang on the lock's outcome, a failing lock
        // would withdraw the ghost that failed it, and the two would alternate without end
        // (B-133). Nothing past this point demands anything, so no outcome here can move the
        // root it reads.
        let unlockedFolders: [String]
        switch try lockCheck.outcome(locks: lockValues,
                                     contentRoots: input.inputValues[Self.dependencyContentRoots] ?? [:]) {
        case .waiting(let folders):
            return try pendingOutput(
                reason: "SwiftFormulaConverter: waiting for the lock of \(folders.count) vendored package(s):\n"
                      + folders.map { "  \($0)" }.joined(separator: "\n"),
                demands: demands)
        case .failed(let problems):
            return try pendingOutput(
                reason: "SwiftFormulaConverter: " + problems.map(\.description).joined(separator: "\n\n"),
                demands: demands)
        case .passed(let unlocked):
            unlockedFolders = unlocked
        }

        // ── all manifests present — generate formula ──────────────────────────
        let formula: String
        do {
            formula = try generateFormula(rootManifest: rootManifest,
                                          externalManifests: availableManifests,
                                          rootPackageFolder: rootPackageFolder,
                                          platform: platform,
                                          binaryArtifacts: binaryWalk.locations,
                                          clangInfo: { target, folder in
                                              PackageClangTarget(targetFolder: folder, moduleName: target.moduleName,
                                                                 rules: target.clangRules, manifests: folderManifests)
                                          },
                                          resources: { target, folder in
                                              PackageResources.detect(rules: target.resourceRules, targetFolder: folder,
                                                                      manifests: folderManifests)
                                          })
        } catch let error as SwiftPackageConversionError {
            return try pendingOutput(reason: "SwiftFormulaConverter: \(error)", demands: demands)
        }
        // Said once the formula is made, not on the passes that wait for it, so a
        // conversion says it once.
        if !unlockedFolders.isEmpty {
            NodeNotice.post(DependencyLockCheck.notice(unlocked: unlockedFolders))
        }
        return .init(
            outputValues: [Self.formulaOutput: .value(try formula.intern()),
                           Self.infoLog: .value("")],
            inputWireSpecs: demands.wireSpecs(selfWiring: selfWiringSpecs))
    }

    /// Everything a pass asks for on the dynamic ports, filled in as the pass gets further.
    /// Every exit carries all of it — a spec left out of an output is unwired — so what a
    /// pass demands follows what has arrived, never which check stopped it.
    private struct Demands {
        var packageManifests:      [String: GraphSpecNode] = [:]
        var locks:                 [String: GraphSpecNode] = [:]
        var contentRoots:          [String: GraphSpecNode] = [:]
        var awaitedPackageFolders: [String: GraphSpecNode] = [:]
        var targetFolders:         [String: GraphSpecNode] = [:]
        var targetSubfolders:      [String: GraphSpecNode] = [:]
        var linkerConfiguration:   [String: GraphSpecNode] = [:]
        var binaryArtifactFolders: [String: GraphSpecNode] = [:]

        /// The specs by port, with the node's own package wires, which a formula naming
        /// the package by `path` stands for.
        func wireSpecs(selfWiring: [String: [String: GraphSpecNode]]) -> [String: [String: GraphSpecNode]] {
            selfWiring.merging([SwiftFormulaConverter.externalPackageJSONs:   packageManifests,
                                SwiftFormulaConverter.dependencyLocks:        locks,
                                SwiftFormulaConverter.dependencyContentRoots: contentRoots,
                                SwiftFormulaConverter.targetFolders:          targetFolders,
                                SwiftFormulaConverter.targetSubfolders:       targetSubfolders,
                                SwiftFormulaConverter.awaitedPackageFolders:  awaitedPackageFolders,
                                SwiftFormulaConverter.linkerConfiguration:    linkerConfiguration,
                                SwiftFormulaConverter.binaryArtifactFolders:  binaryArtifactFolders]) { _, new in new }
        }
    }

    // Returns a noValue output that still carries the current specs — the node's own
    // package wires included, since a spec left out of any output is unwired — so
    // applySpecs keeps (or creates) the needed wires.
    private func pendingOutput(reason: String, demands: Demands = Demands()) throws -> ProcessOutput {
        .init(outputValues: [Self.formulaOutput: .noValue(reason: .error(messageDataObjectHash: try reason.intern())),
                             Self.infoLog: .value("")],
              inputWireSpecs: demands.wireSpecs(selfWiring: selfWiringSpecs))
    }

    // MARK: - Stalls

    /// Explains a stall in terms the user can act on.
    ///
    /// Naming only the paths being waited on is the least useful thing this could say: for a
    /// git dependency that path is a *convention this build system invented*, so a user
    /// seeing `input:/repo/GRDB.swift` has no way to connect it to the `.package(url:)` line
    /// in their manifest, and no hint that nothing is ever going to arrive on its own.
    private func describeStall(missingPaths: [String], origins: [String: String?]) -> String {
        let lines = missingPaths.map { path -> String in
            guard let origin = origins[path] ?? nil else {
                return "  \(path) — declared as a local path dependency, but nothing is there"
            }
            return "  \(path) — where \(origin) is expected to be vendored"
        }

        return "SwiftFormulaConverter: waiting for \(missingPaths.count) package(s):\n"
             + lines.joined(separator: "\n")
             + "\nThis build system never fetches anything: a dependency must be present in "
             + "the input file system at the path above, pushed like any other source. "
             + "`semel-swift prepare <folder>` resolves and copies every git dependency into "
             + "the root's Dependencies folder."
    }

    // MARK: - Binary targets (B-77, B-133)

    /// A binary target's artifact, as its manifest declares it.
    enum BinaryArtifact: Equatable {
        /// `.binaryTarget(url:checksum:)`: a zip SwiftPM downloads, holding an `.xcframework`.
        case remote(url: String, checksum: String?)
        /// `.binaryTarget(path:)`: an `.xcframework` folder or a zip of one, relative to
        /// the package.
        case local(path: String)

        /// Whether the artifact reaches the build through the package's `semel-artifacts`
        /// folder — downloaded, or a zip unzipped — rather than being the folder it names.
        var isVendoredIntoArtifactsFolder: Bool {
            switch self {
            case .remote:             return true
            case .local(let path):    return path.hasSuffix(".zip")
            }
        }
    }

    /// Where a binary target's `.xcframework` is, as the folders that have arrived say.
    enum BinaryArtifactLocation: Equatable {
        /// The `.xcframework` folder, which the slice selector reads.
        case xcframework(String)
        /// Nothing is where the artifact should be: the folder named.
        case missing(String)
        /// Something is there, and it is not an `.xcframework` — an `.artifactbundle`, an
        /// executable for a plugin — or the manifest names something that could not be
        /// one: the path, and what the folder holds when there is a folder.
        case notAnXCFramework(String, contents: [String])
    }

    /// The folders every binary target's `.xcframework` is found through, one level a pass,
    /// and where each one is once the walk is done, keyed `<package folder>/<target>`.
    ///
    /// A `path:` `.xcframework` is asked for directly: the manifest names it, as it names a
    /// target's source folder. A downloaded or zipped one is in `semel-artifacts/<Target>`,
    /// where `prepare` put it or did not; the walk asks for the package folder, then for
    /// `semel-artifacts` only if the package lists it, then for the target's folder only if
    /// that lists it, so nothing it asks for under a vendored package is a ghost that package's
    /// content root would fold (B-133).
    private struct BinaryArtifactWalk {
        var specs: [String: GraphSpecNode] = [:]
        /// The folders asked for whose manifests have not arrived, sorted.
        var waiting: [String] = []
        var locations: [String: BinaryArtifactLocation] = [:]

        init(packages: [(folder: String, manifest: SPMManifest)], rootFolderManifest: FolderManifest,
             arrived: [String: FolderManifest]) {
            func lists(_ manifest: FolderManifest, folder name: String) -> Bool {
                manifest.entries.contains { $0.isFolder && $0.isPinned && $0.name == name }
            }
            var unanswered = Set<String>()
            for (packageFolder, manifest) in packages {
                for target in manifest.targets {
                    guard let artifact = target.binaryArtifact else {
                        continue
                    }
                    let key = "\(packageFolder)/\(target.name)"
                    if case .local(let path) = artifact, !artifact.isVendoredIntoArtifactsFolder {
                        let folder = target.folder(in: packageFolder)
                        guard path.hasSuffix(".xcframework") else {
                            locations[key] = .notAnXCFramework(folder, contents: [])
                            continue
                        }
                        specs[folder] = .folderManifest(at: folder)
                        guard let xcframework = arrived[folder] else {
                            unanswered.insert(folder)
                            continue
                        }
                        locations[key] = xcframework.entries.contains(where: \.isPinned) ? .xcframework(folder) : .missing(folder)
                        continue
                    }

                    let artifactsFolder = "\(packageFolder)/\(SwiftFormulaConverter.artifactsFolderName)"
                    let targetFolder    = "\(artifactsFolder)/\(target.name)"
                    var packageManifest: FolderManifest? = rootFolderManifest
                    if packageFolder != rootFolderManifest.baseFolderPath {
                        specs[packageFolder] = .folderManifest(at: packageFolder)
                        packageManifest = arrived[packageFolder]
                    }
                    guard let packageManifest else {
                        unanswered.insert(packageFolder)
                        continue
                    }
                    guard lists(packageManifest, folder: SwiftFormulaConverter.artifactsFolderName) else {
                        locations[key] = .missing(targetFolder)
                        continue
                    }
                    specs[artifactsFolder] = .folderManifest(at: artifactsFolder)
                    guard let artifactsManifest = arrived[artifactsFolder] else {
                        unanswered.insert(artifactsFolder)
                        continue
                    }
                    guard lists(artifactsManifest, folder: target.name) else {
                        locations[key] = .missing(targetFolder)
                        continue
                    }
                    specs[targetFolder] = .folderManifest(at: targetFolder)
                    guard let targetManifest = arrived[targetFolder] else {
                        unanswered.insert(targetFolder)
                        continue
                    }
                    let held = targetManifest.entries.filter(\.isPinned).map(\.name).sorted()
                    if let xcframework = targetManifest.entries.filter({ $0.isFolder && $0.isPinned && $0.name.hasSuffix(".xcframework") })
                                                               .map(\.name).min() {
                        locations[key] = .xcframework("\(targetFolder)/\(xcframework)")
                    } else if held.isEmpty {
                        locations[key] = .missing(targetFolder)
                    } else {
                        locations[key] = .notAnXCFramework(targetFolder, contents: held)
                    }
                }
            }
            waiting = unanswered.sorted()
        }
    }

    /// A binary target some product reaches whose artifact the conversion cannot use.
    struct UnbuiltBinaryTarget: Equatable {
        let package:       String
        let packageFolder: String
        let target:        String
        let artifact:      BinaryArtifact
        /// Why: nothing where the artifact should be, or not an `.xcframework`.
        let location:      BinaryArtifactLocation
        /// The products of the converted package that reach it, sorted.
        let products:      [String]
    }

    /// Why a conversion that has every input still makes no formula, by case.
    enum SwiftPackageConversionError: Error, Equatable, CustomStringConvertible {
        /// A product reaches a binary target whose artifact is not an `.xcframework` that is
        /// there. The formula could leave it out, but what links the product would then fail
        /// naming a symbol, which explains nothing; so the conversion stops and names the
        /// target instead. A binary target no product reaches is not needed and says nothing.
        ///
        /// What is built is an `.xcframework`, by `url:` or by `path:`, zipped or not (B-77).
        /// What still is not (B-133): an artifact that is anything else — an
        /// `.artifactbundle`, which holds executables for plugins rather than a library.
        case binaryTargetsNotBuilt([UnbuiltBinaryTarget])

        var description: String {
            switch self {
            case .binaryTargetsNotBuilt(let targets):
                return targets.map { target in
                    let products = target.products.joined(separator: ", ")
                    let named = "binary target \(target.target) of package \(target.package)"
                    let reaching = "so what reaches it cannot be built either — product(s) \(products)"
                    switch target.location {
                    case .missing(let folder):
                        let origin: String
                        switch target.artifact {
                        case .remote(let url, _):
                            origin = "the artifact downloaded from \(url) is not vendored: nothing is at \(folder). "
                                   + "This build system never fetches anything; `semel-swift prepare` copies what "
                                   + "SwiftPM downloaded and checked there"
                        case .local(let path) where path.hasSuffix(".zip"):
                            origin = "\(target.packageFolder)/\(path) is not unzipped: nothing is at \(folder). "
                                   + "`semel-swift prepare` unzips it there"
                        case .local:
                            origin = "nothing is at \(folder), the path its manifest names"
                        }
                        return "\(named): \(origin); \(reaching)"
                    case .notAnXCFramework(let path, let contents):
                        let held = contents.isEmpty ? "" : ", which holds \(contents.joined(separator: ", "))"
                        return "\(named) is not built (B-133): its artifact \(path)\(held) is not an .xcframework, "
                             + "and an .xcframework is the only binary artifact linked here; \(reaching)"
                    case .xcframework:
                        return "\(named)"
                    }
                }.joined(separator: "\n")
            }
        }
    }

    // MARK: - semel.config

    /// The project's config file, beside the root: `semel.config`, its choices.
    static let configFileName = "semel.config"
    /// The machine's, beside it: the tools and SDK, written by `semel-clang` or
    /// `semel-swift prepare` and laid under the project's (B-109).
    static let machineConfigFileName = MachineFileWriter.fileName
    /// The folder under the root where `semel-swift` puts every checkout.
    static let dependenciesFolderName = "Dependencies"

    /// The settings a package is configured by: the project's `semel.config` laid over the
    /// machine's `semel.machine.config`, both beside the root, and this namespace's slice
    /// selected out of the two.
    ///
    /// Named in the spec rather than looked up, so the wires exist before the files do — an
    /// absent file is a ghost, and pushing it later fills the wire and rebuilds what depends on
    /// it without a rescan.
    static func configSelector(namespace: String, packageFolder: String) -> String {
        let settings = "ConfigMerger(base: ['machine': StaticFile(path: '\(packageFolder)/\(machineConfigFileName)').output], "
                     + "override: ['project': StaticFile(path: '\(packageFolder)/\(configFileName)').output]).output"
        return "ConfigFilter(prefix: '\(namespace)', input: ['config': \(settings)]).output"
    }

    /// Renders the selector for `namespace` with `literals` laid over it: a `ConfigMerger`
    /// whose `base` is the selector and whose `override` is a `SettingsLiteral` (B-120), or
    /// the selector alone when there are no literals.
    ///
    /// The literals win over the file: they are manifest-derived — `moduleName`, `linkage`
    /// and the like — so they describe what the target *is*, and a config file must not be
    /// able to override identity through the settings it supplies.
    ///
    /// Sorted, because these become a formula string that becomes a node's graphSpec — and
    /// Dictionary iteration order is seeded per process, so an unsorted render would give
    /// the same package a different node identity on every run.
    static func configurationExpression(namespace: String,
                                        packageFolder: String,
                                        literals: [String: String]) -> String {
        let selector = configSelector(namespace: namespace, packageFolder: packageFolder)
        guard !literals.isEmpty else {
            return selector
        }
        let rendered = literals.sorted { $0.key < $1.key }
                               .map { "\($0.key): '\($0.value)'" }
                               .joined(separator: ", ")
        return "ConfigMerger(base: ['\(SettingsNodes.literalsBaseWire)': \(selector)], "
             + "override: ['\(SettingsNodes.literalsOverrideWire)': SettingsLiteral(\(rendered)).output]).output"
    }

    /// Spec string for a `SwiftPackageReader` that reads the
    /// `Package.swift` at `packageFilePath` in the input filesystem.
    ///
    /// The reader is a tool like any other: it shells out to `swift package dump-package`
    /// and so needs a `toolDescriptor` telling it which toolchain to run. Nothing defaults,
    /// so a reader wired to an empty `SettingsLiteral()` fails before any target is compiled —
    /// which is why the selector belongs here rather than only on the compiler and linker.
    ///
    /// `rootPackageFolder` is where the config file is read from, and it is not always the
    /// folder holding `packageFilePath`: configuration is a property of the build, not of the
    /// package being read, and a consuming project cannot write a config file inside a
    /// vendored dependency it does not own.
    static func packageReaderSpec(packageFilePath: String,
                                         rootPackageFolder: String) -> GraphSpecNode {
        GraphSpecNode(SwiftPackageReader.self, inputs: [
            SwiftPackageReader.configuration: ["config": configurationTree(namespace: SwiftPackageReaderConfiguration.settingNamespace,
                                                                          packageFolder: rootPackageFolder,
                                                                          literals: [:])],
            SwiftPackageReader.packageFile: [packageFilePath: .staticFile(at: packageFilePath)],
        ]).port(SwiftPackageReader.packageJSON)
    }

    /// The tree `configurationExpression` renders, for a demand the converter itself
    /// makes rather than a formula it emits (B-115): the namespace's slice of the
    /// project's config laid over the machine's, with `literals` over that.
    static func configurationTree(namespace: String, packageFolder: String, literals: [String: String]) -> GraphSpecNode {
        let settings = GraphSpecNode.configMerger(
            base:     ["machine": .staticFile(at: "\(packageFolder)/\(machineConfigFileName)")],
            override: ["project": .staticFile(at: "\(packageFolder)/\(configFileName)")])
        return .literals(literals, over: .configFilter(prefix: namespace, input: ["config": settings]))
    }

    // MARK: - SPM JSON model

    private struct SPMManifest: Decodable {
        let name: String
        let targets: [SPMTarget]
        let products: [SPMProduct]
        /// Package dependencies as local paths relative to this manifest, each carrying
        /// enough of where it came from to explain itself when nothing is at that path.
        let packageDependencies: [SPMPackageDependency]

        enum CodingKeys: String, CodingKey {
            case name, targets, products, dependencies
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self,      forKey: .name)
            targets = try c.decode([SPMTarget].self,  forKey: .targets)
            products = try c.decode([SPMProduct].self, forKey: .products)
            let rawDeps = (try? c.decode([AnySPMDependency].self, forKey: .dependencies)) ?? []
            packageDependencies = rawDeps.flatMap { $0.dependencies }
        }

        static func decode(_ json: String) throws -> SPMManifest {
            try JSONDecoder().decode(SPMManifest.self, from: Data(json.utf8))
        }

        /// The package dependencies some target actually uses — what SwiftPM itself checks
        /// out. A dependency declared for a plugin or for documentation (swift-markdown
        /// names swift-docc-plugin) is used by no target, SwiftPM never fetches it, and a
        /// build waiting for it would wait forever.
        ///
        /// A `product` dependency names its package. A `byName` dependency that is not a
        /// local target could be a product of any dependency, so when one exists every
        /// dependency is followed: waiting for one too many is a stall the user can see;
        /// dropping one that was needed is a compile failure that explains nothing.
        func referencedDependencies() -> [SPMPackageDependency] {
            let localTargets = Set(targets.map(\.name))
            var referenced   = Set<String>()
            // A test target is not built here, so what only it depends on — RevenueCat's
            // Nimble and snapshot testing — is not fetched by a consumer's resolution
            // either, and waiting for it would wait forever.
            for target in targets where target.type != "test" {
                for dependency in target.dependencies {
                    if let package = dependency.packageName {
                        referenced.insert(package.lowercased())
                    } else if dependency.isByName, let name = dependency.targetName, !localTargets.contains(name) {
                        return packageDependencies
                    }
                }
            }
            return packageDependencies.filter { referenced.contains($0.identity.lowercased()) }
        }
    }

    // Decodes one element of the top-level "dependencies" array down to local paths.
    //
    // fileSystem entries carry their path directly, resolved against the manifest that
    // declared it.  sourceControl entries name a git URL and registry entries a
    // `scope.name` identity, neither of which this build system ever fetches — every input
    // must come through the graph — so the package is expected to be *vendored* into the
    // input filesystem under the root package's `Dependencies` folder, whatever package
    // named it: "<root>/Dependencies/<RepositoryName>" for a git URL,
    // "<root>/Dependencies/<identity>" for a registry package. Flat, because SwiftPM
    // guarantees one identity per package graph, and it is where `semel-swift` copies
    // SwiftPM's own checkouts (docs/superpowers/specs/2026-09-12-semel-swift-design.md).
    // A registry identity keeps its case ("mona.LinkedList"), unlike a git identity, so
    // it can name a directory directly.
    //
    // What *is* checked is that the copy has not moved since it was vendored: the lock
    // beside it records the folder's content root, and a copy folding to anything else
    // stops the build (B-06, `DependencyLockCheck`).
    //
    // ISSUE: a sourceControl or registry dependency's version requirement is not checked
    // against the vendored copy.  Nothing here can read a version out of a bare source
    // tree, so a manifest asking for `from: "7.11.1"` builds against whatever was vendored.
    // The lock records the version `prepare` resolved, but only records it: SwiftPM chose
    // it against the requirement, and a lock written by hand says whatever its writer said.
    private struct AnySPMDependency: Decodable {
        let dependencies: [SPMPackageDependency]

        enum CodingKeys: String, CodingKey { case fileSystem, sourceControl, registry }

        init(from decoder: Decoder) throws {
            let c             = try decoder.container(keyedBy: CodingKeys.self)
            let fileSystem    = (try? c.decode([SPMFileSystemDependency].self,    forKey: .fileSystem))    ?? []
            let sourceControl = (try? c.decode([SPMSourceControlDependency].self, forKey: .sourceControl)) ?? []
            let registry      = (try? c.decode([SPMRegistryDependency].self,      forKey: .registry))      ?? []

            dependencies =
                fileSystem.map { SPMPackageDependency.local(identity: $0.identity, path: $0.path) } +
                sourceControl.compactMap { control in
                    control.repositoryName.map {
                        SPMPackageDependency.vendored(identity: control.identity ?? $0, name: $0,
                                                      origin: control.repositoryURL ?? $0)
                    }
                } +
                registry.map {
                    SPMPackageDependency.vendored(identity: $0.identity, name: $0.identity,
                                                  origin: "registry package \($0.identity)")
                }
        }
    }

    /// Where a package dependency's sources are. A `local` one states its path in the
    /// manifest, relative to the declaring package. A `vendored` one is a git or registry
    /// package that `semel-swift` placed under the root's `Dependencies` folder; `origin`
    /// names the repository URL or registry package the folder stands for — which is
    /// exactly what a user needs told when nothing is at that path. `identity` is what a
    /// target's `.product(name:package:)` names it by.
    private enum SPMPackageDependency {
        case local(identity: String, path: String)
        case vendored(identity: String, name: String, origin: String)

        /// The dependency's folder in the input file system.
        func resolvedPath(declaringPackage: String, root: String, resolve: (String, String) -> String) -> String {
            switch self {
            case .local(_, let path):
                return resolve(path, declaringPackage)
            case .vendored(_, let name, _):
                return "\(root)/\(SwiftFormulaConverter.dependenciesFolderName)/\(name)"
            }
        }

        var identity: String {
            switch self {
            case .local(let identity, _):       return identity
            case .vendored(let identity, _, _): return identity
            }
        }

        var origin: String? {
            if case .vendored(_, _, let origin) = self { return origin }
            return nil
        }
    }

    private struct SPMRegistryDependency: Decodable {
        let identity: String
    }

    private struct SPMFileSystemDependency: Decodable {
        let identity: String
        let path: String
    }

    private struct SPMSourceControlDependency: Decodable {
        /// SwiftPM's identity for the package — the lowercased repository name — which is
        /// what a target's product dependency names it by.
        let identity: String?
        /// nil when the location is not a remote URL, or the URL names nothing usable.
        let repositoryName: String?
        /// Kept verbatim so a stalled build can name what it is waiting for.
        let repositoryURL: String?

        private struct Location: Decodable {
            struct Remote: Decodable { let urlString: String }
            let remote: [Remote]?
        }

        enum CodingKeys: String, CodingKey { case location, identity }

        init(from decoder: Decoder) throws {
            let c    = try decoder.container(keyedBy: CodingKeys.self)
            let url  = (try? c.decode(Location.self, forKey: .location))?.remote?.first?.urlString
            identity       = try? c.decode(String.self, forKey: .identity)
            repositoryURL  = url
            repositoryName = url.flatMap { Self.directoryName(forRepositoryURL: $0) }
        }

        /// "https://github.com/groue/GRDB.swift.git" -> "GRDB.swift": the name
        /// `semel-swift prepare` vendors it under, by the one rule both read.
        static func directoryName(forRepositoryURL urlString: String) -> String? {
            DependencyLock.folderName(forRepositoryURL: urlString)
        }
    }

    private struct SPMTarget: Decodable {
        let name: String
        let type: String?
        let path: String?
        let dependencies: [SPMTargetDependency]
        /// Explicit `sources:` list, relative to the target's path.  Empty means the whole
        /// directory, which is the usual case.
        let sources: [String]
        /// `exclude:` list, relative to the target's path.
        let exclude: [String]
        /// `.swiftLanguageMode(.v6)` from the target's `swiftSettings`, as the version string
        /// (`"6"`). nil when the target declares none. Other settings kinds are not carried.
        let languageMode: String?
        /// `publicHeadersPath:`, relative to the target's path; nil means SwiftPM's `include`.
        let publicHeadersPath: String?
        /// The target's unconditional `.define` settings from `cSettings` and `cxxSettings`,
        /// as written — `FOO`, `BAR=2` — in manifest order. SwiftPM applies both lists to
        /// every file of a C target, whatever its language, so they are read as one.
        ///
        /// A conditional one — `.when(platforms: [.windows])`, swift-cmark's only kind, or
        /// `.when(configuration: .debug)` — is not carried: whether it holds depends on the
        /// platform and configuration being built, and only a linker setting is decided for
        /// the platform yet (`linkerSettings`).
        let cDefines: [String]
        /// The target's unconditional `.headerSearchPath` settings from `cSettings` and
        /// `cxxSettings`, relative to its folder, in manifest order; conditional ones are
        /// not carried, for the reason conditional defines are not.
        let cHeaderSearchPaths: [String]
        /// The target's `.linkedFramework` and `.linkedLibrary` settings, in manifest order,
        /// with the platforms each is conditional on (B-55). A Swift target's count as a C
        /// target's do: SwiftPM links them into every product that reaches the target.
        let linkerSettings: [SPMLinkerSetting]
        /// Non-decoded. Set only on synthetic targets created for external packages.
        var overridePackageFolder: String?
        /// Non-decoded. What the target's folder tree said, once it arrived: nil means Swift.
        var clangInfo: PackageClangTarget?

        /// Non-decoded. The resources the target's folder holds, by the manifest's rules
        /// and SwiftPM's types, once the folder tree has been walked (B-77).
        var resources: [PackageResource] = []

        /// Non-decoded. The name of the package the target belongs to, for its bundle.
        var packageName: String?

        /// The manifest's `resources:` rules, relative to the target folder.
        let declaredResources: [SPMResource]

        /// `FoodTruckKit_FoodTruckKit`: the bundle a target's resources are built into.
        var resourceBundleName: String {
            FormulaIdentifier.resourceBundleName(package: packageName ?? "", target: name)
        }

        /// What the resource reading needs of the manifest, without the manifest's types.
        var resourceRules: PackageResources.Rules {
            .init(declared: declaredResources.map { .init(path: $0.path, isCopy: $0.rule == .copy) },
                  sources: sources, exclude: exclude)
        }

        /// What reading the target as a C target needs of the manifest.
        var clangRules: PackageClangTarget.Rules {
            .init(sources: sources, exclude: exclude, publicHeadersPath: publicHeadersPath,
                  headerSearchPaths: cHeaderSearchPaths)
        }

        var isClangTarget: Bool { clangInfo != nil }

        /// Whether a linker setting holds on some platforms only, so the conversion has to
        /// know which platform is being built.
        var hasPlatformConditionalLinkerSetting: Bool {
            linkerSettings.contains { $0.platforms != nil }
        }

        /// What linking this target's objects needs on `platform` — SwiftPM's name for
        /// it, nil when no setting is conditional on one: the frameworks and libraries
        /// whose condition holds, and the C++ runtime when its sources hold C++.
        func linkRequirements(platform: String?) -> LinkRequirements {
            let holding = linkerSettings.filter { setting in
                guard let platforms = setting.platforms else {
                    return true
                }
                guard let platform else {
                    return false
                }
                return platforms.contains(platform)
            }
            return LinkRequirements(frameworks: holding.compactMap(\.frameworkName),
                                    libraries:  holding.compactMap(\.libraryName),
                                    cxxRuntime: clangInfo?.compilesCxx ?? false)
        }

        /// Whether a build compiles this target at all: not a test, a system library, a
        /// plugin, a macro or a binary target.
        var isCompilable: Bool {
            !isSystemLibrary && !isBinary && !["test", "plugin", "macro"].contains(type ?? "")
        }

        /// A `.binaryTarget`: an artifact built elsewhere, with nothing here to compile and
        /// no source folder to ask for — a remote one has no folder in the package at all.
        var isBinary: Bool { type == "binary" }

        /// What a binary target's artifact is, as the manifest declares it: downloaded by
        /// `url:` and checked against `checksum:`, or at `path:` in the package.
        var binaryArtifact: BinaryArtifact? {
            guard isBinary else {
                return nil
            }
            if let url {
                return .remote(url: url, checksum: checksum)
            }
            return .local(path: sourcesRelativePath)
        }

        /// A remote binary target's `url:` and `checksum:`; nil for every other target.
        let url: String?
        let checksum: String?

        enum CodingKeys: String, CodingKey {
            case name, type, path, dependencies, sources, exclude, settings, resources, publicHeadersPath, url, checksum
        }

        /// One entry of a target's `resources` as `dump-package` emits it:
        /// `{"path": "Resources", "rule": {"process": {}}}`; a rule the reader does not
        /// know is read as `process`, the common one.
        struct SPMResource: Decodable, Equatable {
            enum Rule: Equatable {
                case process
                case copy
            }

            let path: String
            let rule: Rule

            enum CodingKeys: String, CodingKey { case path, rule }

            init(path: String, rule: Rule) {
                self.path = path
                self.rule = rule
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                path = try container.decode(String.self, forKey: .path)
                let ruleObject = (try? container.decode([String: [String: String]].self, forKey: .rule)) ?? [:]
                rule = ruleObject["copy"] != nil ? .copy : .process
            }
        }

        /// One entry of a target's `settings` as `dump-package` emits it:
        /// `{"kind": {"swiftLanguageMode": {"_0": "6"}}, "tool": "swift"}`, with a
        /// `condition` object beside them when it is `.when(…)`. Kinds whose payload is not
        /// a string (`unsafeFlags` carries an array) decode as nil and are ignored, which is
        /// what "not carried" means.
        private struct SPMSetting: Decodable {
            let kind: [String: [String: String]]?
            let tool: String?
            let isConditional: Bool
            /// `.when(platforms:)`, as `dump-package` names them (`macos`, `ios`); empty when
            /// the setting names none, which is every platform.
            let platformNames: [String]
            /// `.when(configuration:)`: `debug` or `release`; nil when it names none.
            let configuration: String?

            enum CodingKeys: String, CodingKey { case kind, tool, condition }

            /// `{"platformNames": ["ios"], "config": "debug"}`.
            private struct Condition: Decodable {
                let platformNames: [String]?
                let config: String?
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                kind          = try? container.decode([String: [String: String]].self, forKey: .kind)
                tool          = try? container.decode(String.self, forKey: .tool)
                isConditional = container.contains(.condition) && !((try? container.decodeNil(forKey: .condition)) ?? false)
                let condition = try? container.decode(Condition.self, forKey: .condition)
                platformNames = condition?.platformNames ?? []
                configuration = condition?.config
            }

            /// A `.linkedFramework` or `.linkedLibrary`, with the platforms it holds for.
            ///
            /// One conditional on a configuration is not carried: nothing here builds a
            /// package in one configuration or the other, so there is no answer to whether
            /// it holds. `unsafeFlags` is not carried either; its payload is an array, which
            /// `kind` does not decode.
            var linkerSetting: SPMLinkerSetting? {
                guard tool == "linker", configuration == nil else {
                    return nil
                }
                let platforms = platformNames.isEmpty ? nil : platformNames
                if let framework = kind?["linkedFramework"]?["_0"] {
                    return .init(item: .framework(framework), platforms: platforms)
                }
                if let library = kind?["linkedLibrary"]?["_0"] {
                    return .init(item: .library(library), platforms: platforms)
                }
                return nil
            }

            /// The value of an unconditional `.define` for C or C++, as written.
            var unconditionalDefine: String? {
                unconditionalClangSetting("define")
            }

            /// The folder of an unconditional `.headerSearchPath` for C or C++, relative to
            /// the target's folder.
            var unconditionalHeaderSearchPath: String? {
                unconditionalClangSetting("headerSearchPath")
            }

            private func unconditionalClangSetting(_ name: String) -> String? {
                guard !isConditional, ["c", "cxx"].contains(tool ?? "") else {
                    return nil
                }
                return kind?[name]?["_0"]
            }
        }

        init(from decoder: Decoder) throws {
            let c        = try decoder.container(keyedBy: CodingKeys.self)
            name         = try c.decode(String.self, forKey: .name)
            type         = try? c.decode(String.self, forKey: .type)
            path         = try? c.decode(String.self, forKey: .path)
            dependencies = (try? c.decode([SPMTargetDependency].self, forKey: .dependencies)) ?? []
            sources      = (try? c.decode([String].self, forKey: .sources)) ?? []
            exclude      = (try? c.decode([String].self, forKey: .exclude)) ?? []
            declaredResources = (try? c.decode([SPMResource].self, forKey: .resources)) ?? []
            let settings = (try? c.decode([SPMSetting].self, forKey: .settings)) ?? []
            languageMode = settings.compactMap { $0.kind?["swiftLanguageMode"]?["_0"] }.first
            cDefines     = settings.compactMap(\.unconditionalDefine)
            cHeaderSearchPaths = settings.compactMap(\.unconditionalHeaderSearchPath)
            linkerSettings = settings.compactMap(\.linkerSetting)
            publicHeadersPath = try? c.decode(String.self, forKey: .publicHeadersPath)
            url          = try? c.decode(String.self, forKey: .url)
            checksum     = try? c.decode(String.self, forKey: .checksum)
            overridePackageFolder = nil
        }

        // SPM default: Sources/<TargetName> relative to the package root.
        var sourcesRelativePath: String { path ?? "Sources/\(name)" }

        /// The target's folder under `packageFolder`, spelled as the walk spells a folder.
        /// A manifest may put a target at the package root — `path: ""` or `"."`
        /// (PLCrashReporter) — or end its path with a `/`, and each is the plain folder: a
        /// demand spelled `…/pkg/` is a second node for the package folder's own name.
        func folder(in packageFolder: String) -> String {
            PackageClangTarget.joined(packageFolder, PackageClangTarget.normalized(sourcesRelativePath))
        }

        /// The module the target compiles to. A target's name is free text — `semel-clang`,
        /// `swift-markdown` — and a Swift module name is an identifier, so SwiftPM mangles
        /// one into the other (`c99name`) and every `import` and `.swiftmodule` file uses
        /// the mangled form. The same rule here: any character that is not a letter, a
        /// digit or an underscore becomes an underscore, and a leading digit gets one in
        /// front. Wire names and formula funcs keep the target's own name.
        var moduleName: String { SwiftFormulaConverter.c99Identifier(name) }

        // systemLibrary targets (type == "system-target") wrap C system libraries
        // via a module.modulemap.  They have no Swift sources and cannot be compiled
        // with SwiftCompiler.
        var isSystemLibrary: Bool { type == "system-target" || type == "system" }
    }

    /// One `linkerSettings` entry the link carries (B-55).
    private struct SPMLinkerSetting: Equatable {
        enum Item: Equatable {
            /// `.linkedFramework("Foundation")`: `-framework Foundation`.
            case framework(String)
            /// `.linkedLibrary("z")`: `-lz`.
            case library(String)
        }

        let item: Item
        /// `.when(platforms:)` as SwiftPM names them (`macos`, `ios`); nil for every one.
        let platforms: [String]?

        var frameworkName: String? {
            guard case .framework(let name) = item else { return nil }
            return name
        }

        var libraryName: String? {
            guard case .library(let name) = item else { return nil }
            return name
        }
    }

    /// SwiftPM's name for the platform an SDK builds for, the name a `.when(platforms:)`
    /// uses: `iphonesimulator` builds for `ios`. nil for an SDK it has no name for, on
    /// which no platform-conditional setting holds.
    ///
    /// ISSUE: Mac Catalyst builds against `macosx` with a `-macabi` triple, and is read
    /// here as `macos`.
    static func swiftPMPlatformName(forSDK sdk: String) -> String? {
        switch sdk {
        case "macosx":                        return "macos"
        case "iphoneos", "iphonesimulator":   return "ios"
        case "appletvos", "appletvsimulator": return "tvos"
        case "watchos", "watchsimulator":     return "watchos"
        case "xros", "xrsimulator":           return "visionos"
        case "driverkit":                     return "driverkit"
        default:                              return nil
        }
    }

    // Handles the two dependency shapes emitted by different Swift versions:
    //   array form  – {"byName": ["Name", null]}
    //   object form – {"byName": {"name": "Name", "condition": null}}
    // Both local target names and external product names are extracted; the
    // distinction is resolved at formula-generation time via allTargetsByName.
    private struct SPMTargetDependency: Decodable {
        let targetName: String?
        /// For a `product` dependency, the package it names — `["Markdown", "swift-markdown",
        /// null, null]` — which is what decides whether that package is needed at all.
        let packageName: String?
        /// A `byName` dependency, which may be a local target or a product of any dependency.
        let isByName: Bool

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String)          { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int)       { nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            var found: String?
            var package: String?
            var byName = false

            for key in ["byName", "target", "product"] {
                guard found == nil, c.contains(AnyKey(key)) else { continue }
                if let arr = try? c.decode([String?].self, forKey: AnyKey(key)) {
                    let present = arr.compactMap { $0 }
                    found = present.first
                    if key == "product", present.count >= 2 { package = present[1] }
                } else if let sub = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(key)),
                          let n   = try? sub.decode(String.self, forKey: AnyKey("name")) {
                    found = n
                    if key == "product" { package = try? sub.decode(String.self, forKey: AnyKey("package")) }
                }
                byName = (key == "byName")
            }
            targetName  = found
            packageName = package
            isByName    = byName
        }
    }

    private struct SPMProduct: Decodable {
        let name: String
        let targets: [String]
        let productType: ProductType

        enum ProductType: Equatable { case executable, library(LibraryType), other }

        /// `.library(type:)` as the manifest declares it: `{"library": ["static"]}`.
        enum LibraryType: String { case `static`, dynamic, automatic }

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String)          { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int)       { nil }
        }

        enum CodingKeys: String, CodingKey { case name, targets, type }

        init(name: String, targets: [String], productType: ProductType) {
            self.name        = name
            self.targets     = targets
            self.productType = productType
        }

        init(from decoder: Decoder) throws {
            let c   = try decoder.container(keyedBy: CodingKeys.self)
            name    = try c.decode(String.self,   forKey: .name)
            targets = try c.decode([String].self, forKey: .targets)
            let tc  = try c.nestedContainer(keyedBy: AnyKey.self, forKey: .type)
            if tc.contains(AnyKey("executable")) {
                productType = .executable
            } else if tc.contains(AnyKey("library")) {
                // One-element array: `{"library": ["automatic"]}`. Strict on purpose — a
                // type this converter has never seen must not silently become one it has.
                let names = try tc.decode([String].self, forKey: AnyKey("library"))
                guard let name = names.first, let libraryType = LibraryType(rawValue: name) else {
                    throw DecodingError.dataCorruptedError(forKey: AnyKey("library"), in: tc,
                        debugDescription: "unknown library type \(names) for product '\(name)'")
                }
                productType = .library(libraryType)
            } else {
                productType = .other
            }
        }
    }

    // MARK: - Formula generation

    private func generateFormula(rootManifest: SPMManifest,
                                 externalManifests: [String: SPMManifest],
                                 rootPackageFolder: String,
                                 platform: String?,
                                 binaryArtifacts: [String: BinaryArtifactLocation] = [:],
                                 clangInfo: (SPMTarget, String) -> PackageClangTarget?,
                                 resources: (SPMTarget, String) -> [PackageResource] = { _, _ in [] }) throws -> String {
        // Every lookup below walks the external packages in one fixed order. Dictionary
        // iteration order is seeded per process, so walking the dictionary itself let two
        // packages vending the same name resolve differently on every restart — and the
        // formula text is what every downstream graphSpec is derived from.
        let externalPackages = externalManifests.sorted { $0.key < $1.key }

        // A target with its package folder, what its own folder says about its language,
        // and the resources its folder holds (B-77), which is what every walk below asks.
        func placed(_ target: SPMTarget, in packageFolder: String?) -> SPMTarget {
            var placed = target
            let folder = target.folder(in: packageFolder ?? rootPackageFolder)
            placed.overridePackageFolder = packageFolder
            placed.packageName = packageFolder.flatMap { externalManifests[$0]?.name } ?? rootManifest.name
            placed.clangInfo = clangInfo(target, folder)
            placed.resources = resources(placed, folder)
            return placed
        }

        // Build combined target name → SPMTarget map.
        // External targets carry overridePackageFolder so buildFuncDef uses the
        // correct source root.  Root targets take precedence on any name conflict;
        // between external packages, the lexically first folder does.
        var allTargetsByName: [String: SPMTarget] = [:]
        for (extFolder, extManifest) in externalPackages {
            for target in extManifest.targets where allTargetsByName[target.name] == nil {
                allTargetsByName[target.name] = placed(target, in: extFolder)
            }
        }
        for target in rootManifest.targets {
            allTargetsByName[target.name] = placed(target, in: nil)  // root wins
        }

        // Resolves a dependency name to all SPMTargets it represents.
        // A direct target name returns one element; a product name returns every
        // target listed in that product so multi-target products are fully covered.
        func allTargetsNamed(_ name: String) -> [SPMTarget] {
            if let t = allTargetsByName[name] { return [t] }
            for (extFolder, extManifest) in externalPackages {
                guard let product = extManifest.products.first(where: { $0.name == name }) else { continue }
                return product.targets.compactMap { targetName in
                    extManifest.targets.first(where: { $0.name == targetName }).map { placed($0, in: extFolder) }
                }
            }
            return []
        }

        var blocks: [String] = []
        var emittedFuncs = Set<String>()
        // Every binary target a product reaches whose artifact cannot be used, by its key,
        // with the products reaching it.
        var unbuiltBinaryTargets: [String: (target: SPMTarget, location: BinaryArtifactLocation, reachingProducts: Set<String>)] = [:]

        // A binary target's `.xcframework`, when it is one that is there (B-77).
        func binaryKey(_ target: SPMTarget) -> String {
            "\(target.overridePackageFolder ?? rootPackageFolder)/\(target.name)"
        }
        func binaryLocation(_ target: SPMTarget) -> BinaryArtifactLocation {
            binaryArtifacts[binaryKey(target)] ?? .missing(target.folder(in: target.overridePackageFolder ?? rootPackageFolder))
        }
        func xcframework(of target: SPMTarget) -> String? {
            guard case .xcframework(let folder) = binaryLocation(target) else {
                return nil
            }
            return folder
        }
        // The binary targets reachable from `root` whose `.xcframework` is there, which is
        // what a compile or a link of what reaches them is given.
        func usableBinaryTargets(from root: SPMTarget) -> [SPMTarget] {
            collectReachableBinaryTargets(root: root, lookupAll: allTargetsNamed).filter { xcframework(of: $0) != nil }
        }

        for product in productsToBuild(in: rootManifest) {

            // Every binary target the product reaches, once, in the order met: each has its
            // slice chosen by a node of its own, named before anything that uses it.
            var binaryTargets: [SPMTarget] = []
            var collectedBinary = Set<String>()
            for productTargetName in product.targets {
                for rootTarget in allTargetsNamed(productTargetName) {
                    for target in collectReachableBinaryTargets(root: rootTarget, lookupAll: allTargetsNamed) {
                        let key = binaryKey(target)
                        guard let xcframework = xcframework(of: target) else {
                            unbuiltBinaryTargets[key, default: (target, binaryLocation(target), [])].reachingProducts.insert(product.name)
                            continue
                        }
                        guard collectedBinary.insert(key).inserted else { continue }
                        binaryTargets.append(target)
                        let fn = sliceFuncName(for: target.name)
                        if emittedFuncs.insert(fn).inserted {
                            blocks.append(sliceFuncDef(target: target, xcframework: xcframework, rootPackageFolder: rootPackageFolder))
                        }
                    }
                }
            }

            // All transitively reachable targets in dependency-first order so each func
            // is defined before any func that references it.  Seeded from *every* target
            // the product vends, not just the first: a multi-target product would
            // otherwise link only one of them, and a product whose first target is a
            // system library would collapse to nothing at all.
            var allTargets: [SPMTarget] = []
            var collected = Set<String>()
            // And every C target reached, whose objects the product links too (B-54).
            var clangTargets: [SPMTarget] = []
            var collectedClang = Set<String>()
            for productTargetName in product.targets {
                for rootTarget in allTargetsNamed(productTargetName) {
                    for target in collectTransitiveTargets(root: rootTarget, lookupAll: allTargetsNamed) {
                        guard collected.insert(target.name).inserted else { continue }
                        allTargets.append(target)
                    }
                    // The product's own target first when it is a C one — a C executable's
                    // `main.c`, a library vending a C target — since the walk below starts
                    // from a target's dependencies and never counts the target itself.
                    let ownClangTarget = rootTarget.isClangTarget ? [rootTarget] : []
                    for target in ownClangTarget + collectTransitiveClangTargets(root: rootTarget, lookupAll: allTargetsNamed) {
                        guard collectedClang.insert(target.name).inserted else { continue }
                        clangTargets.append(target)
                    }
                }
            }

            // A product that reduces to no compilable targets — GRDB's `GRDBSQLite`
            // library vends nothing but a .systemLibrary — has no object files to link.
            // Emitting a SwiftLinker for it anyway leaves its required `input` port
            // unwired, which fails the entire ProjectBuilder rather than just that product.
            // One vending only binary targets — Sparkle's — has no linker either, but its
            // funcs are what an app links it by, so they are written (B-77).
            let compiles = !allTargets.isEmpty || !clangTargets.isEmpty
            guard compiles || !binaryTargets.isEmpty else { continue }

            // Each C target's headers as the tree a Swift importer takes, before the compilers
            // that name it (B-55).
            for target in clangTargets {
                let fn = headerTreeFuncName(for: target.name)
                guard emittedFuncs.insert(fn).inserted else { continue }
                blocks.append(headerTreeFuncDef(target: target, packageFolder: rootPackageFolder))
            }

            // Emit one func definition per unique target (shared across products).
            for target in allTargets {
                let fn = compilerFuncName(for: target.name)
                guard !emittedFuncs.contains(fn) else { continue }
                blocks.append(buildFuncDef(target: target,
                                           packageFolder: rootPackageFolder,
                                           lookupAll: allTargetsNamed,
                                           binaryTargets: usableBinaryTargets(from: target)))
                emittedFuncs.insert(fn)
            }

            // Each target's resource bundle, once, and the product's tree of them (B-77):
            // emitted for every product, empty or not, so an app can name it without
            // knowing which targets carry resources. A C target's bundle is built as a Swift
            // one's is, as SwiftPM builds it (PLCrashReporter's privacy manifest).
            var bundleWires: [String] = []
            for target in allTargets + clangTargets where !target.resources.isEmpty {
                let fn = FormulaIdentifier.bundleFunc(forTarget: target.name)
                if emittedFuncs.insert(fn).inserted {
                    blocks.append(resourceBundleFuncDef(target: target, rootPackageFolder: rootPackageFolder))
                }
                bundleWires.append("        '\(target.name)': \(fn)().files")
            }
            blocks.append(
                "func \(FormulaIdentifier.bundlesFunc(forProduct: product.name))() =\n" +
                "    TreeMerger(input: [" + (bundleWires.isEmpty ? "" : "\n" + bundleWires.joined(separator: ",\n") + "\n    ") + "]).files")
            for target in clangTargets {
                let fn = preprocessorFuncName(for: target.name)
                guard !emittedFuncs.contains(fn) else { continue }
                blocks.append(buildPreprocessorFuncDef(target: target,
                                                       packageFolder: rootPackageFolder,
                                                       lookupAll: allTargetsNamed))
                emittedFuncs.insert(fn)
            }

            // Linker configuration.
            //
            // `outputName` is both the file the linker writes and the name the product is
            // published under: ProjectBuilder turns a formula product's label into its
            // path in the output file system.  Labelling the block with the bare product
            // name instead published a linked lib<name>.dylib as plain "<name>", so the
            // file's content and its name disagreed.
            //
            // Which artifact a library becomes follows its declared type. `.dynamic` is
            // the one case SPM links as a dylib. `.automatic` is not "SPM picks dynamic":
            // SPM never links an automatic library on its own (`swift build --product L`
            // leaves only object files) and links it statically into whatever executable
            // depends on it — so an archive is the artifact closest to what SPM would do,
            // and the old "always a dylib" was an assumption, not a choice (B-09).
            let (linkage, outputName): (SwiftLinkage, String) = switch product.productType {
                case .library(.dynamic):                     (.dynamicLibrary, "lib\(product.name).dylib")
                case .library(.static), .library(.automatic): (.staticArchive,  "lib\(product.name).a")
                case .executable, .other:                    (.executable,     product.name)
            }
            // A linked product finds a binary target's framework beside itself, where
            // SwiftPM puts one for a product it builds (B-77). An archive is not linked.
            let linksBinaryTargets = !binaryTargets.isEmpty && linkage != .staticArchive
            var linkerLiterals = ["linkage":    linkage.rawValue,
                                  "outputName": outputName]
            if linksBinaryTargets {
                linkerLiterals[SwiftLinkerConfiguration.frameworksRunpathKey] = "@loader_path"
            }
            let linkerConfig = Self.configurationExpression(
                namespace: SwiftLinkerConfiguration.settingNamespace,
                packageFolder: buildRoot(defaultingTo: rootPackageFolder),
                literals: linkerLiterals)

            // One object-file wire per compiled Swift target (all transitive deps
            // included), and one object per source file of every C target reached: the
            // for-each expands over the target folder's manifest, which ProjectBuilder
            // wires for exactly that.
            let objectWires = allTargets.map { t in
                "        '\(t.name).o': \(compilerFuncName(for: t.name))().object"
            } + clangTargets.flatMap { clangObjectEntries(target: $0, packageFolder: rootPackageFolder) }

            // Every system library the product reaches, so a vendored static archive
            // dropped in one of those folders is linked in.  The linker needs the same
            // folders the compiler already gets for their module maps — see
            // SwiftLinker.libraryFolders.
            var systemLibraryFolderWires: [String] = []
            var wiredSystemLibraries = Set<String>()
            for target in allTargets {
                for systemLibrary in collectTransitiveSystemLibraries(root: target, lookupAll: allTargetsNamed) {
                    guard wiredSystemLibraries.insert(systemLibrary.name).inserted else { continue }
                    let libraryPkgRoot = systemLibrary.overridePackageFolder ?? rootPackageFolder
                    let folderPath     = systemLibrary.folder(in: libraryPkgRoot)
                    systemLibraryFolderWires.append("            '\(systemLibrary.name)': Folder(path: '\(folderPath)').manifest")
                }
            }

            var linkerArgs =
                "        configuration: ['config': \(linkerConfig)],\n" +
                "        input: [\n" +
                objectWires.joined(separator: ",\n") + "\n" +
                "        ]"
            if !systemLibraryFolderWires.isEmpty {
                linkerArgs += ",\n        libraryFolders: [\n" + systemLibraryFolderWires.joined(separator: ",\n") + "\n        ]"
            }

            // What the product's objects need at link beyond themselves (B-55): every
            // framework and library a target it reaches names, and the C++ runtime when one
            // of its C targets has C++. Defined for every product, empty or not, so a
            // formula linking the product's objects — an app — names it without knowing;
            // wired to this product's own linker when it says anything.
            let requirements = (allTargets + clangTargets).reduce(LinkRequirements.none) { union, target in
                union.union(target.linkRequirements(platform: platform))
            }
            let requirementsFunc = FormulaIdentifier.linkRequirementsFunc(forProduct: product.name)
            let requirementsLiterals = requirements.properties.sorted { $0.key < $1.key }
                                                              .map { "\($0.key): '\($0.value)'" }
                                                              .joined(separator: ", ")
            blocks.append("func \(requirementsFunc)() =\n    SettingsLiteral(\(requirementsLiterals)).output")
            if !requirements.isEmpty {
                linkerArgs += ",\n        linkRequirements: ['\(product.name)': \(requirementsFunc)().output]"
            }

            // Every binary target's slice the product reaches, as a tree an app embeds and
            // links (B-77): defined for every product, empty or not, as `bundles_P()` is, so
            // an app names it without knowing. A static library slice is not in it — its
            // archive goes with the product's objects, and nothing embeds it.
            let frameworksFunc = FormulaIdentifier.frameworksFunc(forProduct: product.name)
            let frameworkWires = binaryTargets.map { "        '\($0.name)': \(sliceFuncName(for: $0.name))().frameworks" }
            blocks.append(
                "func \(frameworksFunc)() =\n" +
                "    TreeMerger(input: [" + (frameworkWires.isEmpty ? "" : "\n" + frameworkWires.joined(separator: ",\n") + "\n    ") + "]).files")
            let libraryWires = binaryTargets.map { "'\($0.name)': \(sliceFuncName(for: $0.name))().libraries" }
            if linksBinaryTargets {
                linkerArgs += ",\n        objectTrees: [\n" + libraryWires.map { "            " + $0 }.joined(separator: ",\n") + "\n        ]"
                linkerArgs += ",\n        frameworkTrees: ['\(product.name)': \(frameworksFunc)().files]"
            }

            // What another formula needs to consume this product — an app that imports and
            // links it — as two trees it can name without knowing what is behind them:
            // every transitive target's module, and every object the product links. The
            // funcs are the product's public face; the product statement is for this
            // package's own output.
            let moduleWires = allTargets.map { t in
                "            '\(t.moduleName).swiftmodule': \(compilerFuncName(for: t.name))().swiftmodule"
            }
            // A .swiftmodule records the Clang modules it was built against, so a consumer
            // loading it needs their module maps on its import path too: every C target
            // and system library the product reaches travels in the same tree — a system
            // library's folder, and a C target's header tree — under the target's name.
            var moduleMapTrees: [String] = []
            var wiredModuleMaps = Set<String>()
            for target in allTargets {
                for systemLibrary in collectTransitiveSystemLibraries(root: target, lookupAll: allTargetsNamed)
                where wiredModuleMaps.insert(systemLibrary.name).inserted {
                    let folder = systemLibrary.folder(in: systemLibrary.overridePackageFolder ?? rootPackageFolder)
                    moduleMapTrees.append(Self.folderTreeWire(name: systemLibrary.name, folder: folder))
                }
                for clangTarget in collectTransitiveClangTargets(root: target, lookupAll: allTargetsNamed)
                where wiredModuleMaps.insert(clangTarget.name).inserted {
                    moduleMapTrees.append(headerTreeWire(for: clangTarget.name))
                }
            }
            // And a C target no Swift one reaches: the product's own, for whoever imports it.
            for clangTarget in clangTargets where wiredModuleMaps.insert(clangTarget.name).inserted {
                moduleMapTrees.append(headerTreeWire(for: clangTarget.name))
            }
            // A static library slice's headers, for whoever imports it; a framework carries
            // its own and its tree here is empty.
            for target in binaryTargets where wiredModuleMaps.insert(target.name).inserted {
                moduleMapTrees.append(binaryHeadersWire(for: target.name))
            }
            let swiftModulesTree = moduleWires.isEmpty
                ? "'swift': TreeBuilder(input: []).files"
                : "'swift': TreeBuilder(input: [\n" + moduleWires.joined(separator: ",\n") + "\n        ]).files"
            blocks.append(
                "func \(FormulaIdentifier.modulesFunc(forProduct: product.name))() =\n" +
                "    TreeMerger(input: [\n" +
                "        " + ([swiftModulesTree] + moduleMapTrees).joined(separator: ",\n        ") + "\n" +
                "    ]).files")
            if binaryTargets.isEmpty {
                blocks.append(
                    "func \(FormulaIdentifier.objectsFunc(forProduct: product.name))() =\n" +
                    "    TreeBuilder(input: [\n" +
                    objectWires.joined(separator: ",\n") + "\n" +
                    "    ]).files")
            } else {
                // With every static library slice's archive beside the objects, which an app
                // links as it links them.
                let objectsTree = objectWires.isEmpty
                    ? "'objects': TreeBuilder(input: []).files"
                    : "'objects': TreeBuilder(input: [\n" + objectWires.map { "    " + $0 }.joined(separator: ",\n") + "\n        ]).files"
                blocks.append(
                    "func \(FormulaIdentifier.objectsFunc(forProduct: product.name))() =\n" +
                    "    TreeMerger(input: [\n" +
                    "        " + ([objectsTree] + libraryWires).joined(separator: ",\n        ") + "\n" +
                    "    ]).files")
            }

            guard compiles else { continue }
            let block =
                "product '\(outputName)' =\n" +
                "    SwiftLinker(\n" +
                linkerArgs + "\n" +
                "    ).output"
            blocks.append(block)
        }

        guard unbuiltBinaryTargets.isEmpty else {
            throw SwiftPackageConversionError.binaryTargetsNotBuilt(unbuiltBinaryTargets.sorted { $0.key < $1.key }.compactMap { _, reached in
                reached.target.binaryArtifact.map { artifact in
                    UnbuiltBinaryTarget(package:       reached.target.packageName ?? rootManifest.name,
                                        packageFolder: reached.target.overridePackageFolder ?? rootPackageFolder,
                                        target:        reached.target.name,
                                        artifact:      artifact,
                                        location:      reached.location,
                                        products:      reached.reachingProducts.sorted())
                }
            })
        }
        return blocks.joined(separator: "\n\n")
    }

    /// A system library's folder, its module map in it, as a tree under `name`, for a
    /// product's module tree: `'GRDBSQLite': FolderTreeBuilder(under: 'GRDBSQLite', folder: [...]).files`.
    private static func folderTreeWire(name: String, folder: String) -> String {
        "'\(name)': FolderTreeBuilder(under: '\(name)', folder: ['folder': Folder(path: '\(folder)').manifest]).files"
    }

    // Every product the package should actually produce.
    //
    // `swift build` builds an executable target whether or not a product lists it, and
    // manifests rely on that: this repository's own root manifest declares no products at
    // all and still yields the `semel` binary.  Emitting only declared products
    // produced an empty formula and, worse, no error explaining the silence.
    //
    // Only executables are synthesised.  A library target with no product is an internal
    // dependency of one that does have a product, and a test target is not built here.
    private func productsToBuild(in manifest: SPMManifest) -> [SPMProduct] {
        var result = manifest.products.filter { $0.productType != .other }

        let alreadyCovered = Set(result.flatMap { $0.targets })
        for target in manifest.targets
        where target.type == "executable" && !alreadyCovered.contains(target.name) {
            result.append(SPMProduct(name: target.name, targets: [target.name], productType: .executable))
        }
        return result
    }

    // Returns all targets reachable from `root` in dependency-first topological
    // order (leaves first, root last). `lookupAll` resolves a dependency name to
    // every target it covers (one for a named target, several for a product).
    private func collectTransitiveTargets(root: SPMTarget, lookupAll: (String) -> [SPMTarget]) -> [SPMTarget] {
        var ordered: [SPMTarget] = []
        var visited  = Set<String>()

        func visit(_ target: SPMTarget) {

            guard !visited.contains(target.name) else {
                return
            }

            // System-library targets (module.modulemap wrappers) have no Swift
            // sources.  Skip them here; buildFuncDef handles them separately via
            // inputModuleMapFolders when they appear as a dependency. A C target has
            // none either: its objects come through the clang nodes and its headers
            // reach Swift as a tree on moduleTrees. Nor has a binary target, whose slice
            // reaches the compile and the link as trees of its own (B-77).
            guard !target.isSystemLibrary, !target.isClangTarget, !target.isBinary else {
                return
            }

            visited.insert(target.name)

            for dep in target.dependencies {
                if let depName = dep.targetName {
                    for depTarget in lookupAll(depName) {
                        visit(depTarget)
                    }
                }
            }

            ordered.append(target)
        }

        visit(root)
        return ordered
    }

    // Every system-library target reachable from `root`, in encounter order — directly,
    // or through any chain of regular targets. `collectTransitiveTargets` deliberately
    // stops at system libraries because they have nothing to compile; this walks past
    // them to find the ones a target needs on its import path but never names.
    private func collectTransitiveSystemLibraries(root: SPMTarget, lookupAll: (String) -> [SPMTarget]) -> [SPMTarget] {
        var ordered: [SPMTarget] = []
        var visited = Set<String>()
        var collected = Set<String>()

        func visit(_ target: SPMTarget) {

            guard visited.insert(target.name).inserted else {
                return
            }

            for dep in target.dependencies {
                guard let depName = dep.targetName else {
                    continue
                }

                for depTarget in lookupAll(depName) {
                    guard depTarget.isSystemLibrary else {
                        visit(depTarget)
                        continue
                    }
                    guard collected.insert(depTarget.name).inserted else { continue }
                    ordered.append(depTarget)
                }
            }
        }

        visit(root)
        return ordered
    }

    /// Every binary target reachable from `root`, `root` included: a product may vend one
    /// directly — Sparkle's only product is its binary target — or reach one through its
    /// targets' dependencies.
    private func collectReachableBinaryTargets(root: SPMTarget, lookupAll: (String) -> [SPMTarget]) -> [SPMTarget] {
        var ordered: [SPMTarget] = []
        var visited = Set<String>()

        func visit(_ target: SPMTarget) {
            guard visited.insert(target.name).inserted else {
                return
            }
            if target.isBinary {
                ordered.append(target)
            }
            for dependency in target.dependencies {
                for dependencyTarget in dependency.targetName.map(lookupAll) ?? [] {
                    visit(dependencyTarget)
                }
            }
        }

        visit(root)
        return ordered
    }

    // Every C target reachable from `root` — directly, or through any chain of Swift or C
    // targets, since a C target may depend on another (cmark-gfm-extensions on cmark-gfm).
    // Encounter order; system libraries are not C targets and are left to their own walk.
    private func collectTransitiveClangTargets(root: SPMTarget, lookupAll: (String) -> [SPMTarget]) -> [SPMTarget] {
        var ordered: [SPMTarget] = []
        var visited = Set<String>()

        func visit(_ target: SPMTarget) {
            guard visited.insert(target.name).inserted else {
                return
            }
            for dep in target.dependencies {
                guard let depName = dep.targetName else {
                    continue
                }
                for depTarget in lookupAll(depName) where !depTarget.isSystemLibrary {
                    if depTarget.isClangTarget, !ordered.contains(where: { $0.name == depTarget.name }) {
                        ordered.append(depTarget)
                    }
                    visit(depTarget)
                }
            }
        }

        visit(root)
        return ordered
    }

    /// SwiftPM's `c99name`: `semel-clang` is the module `semel_clang`, `3d-kit` is `_3d_kit`.
    static func c99Identifier(_ name: String) -> String {
        var identifier = String(name.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_") ? character : "_"
        })
        if let first = identifier.first, first.isNumber {
            identifier = "_" + identifier
        }
        return identifier
    }

    // "MyTarget-A" → "compilerMyTarget_A"  (must be a valid formula identifier)
    private func compilerFuncName(for targetName: String) -> String {
        "compiler\(sanitizedIdentifier(targetName))"
    }

    private func preprocessorFuncName(for targetName: String) -> String {
        "preprocess\(sanitizedIdentifier(targetName))"
    }

    private func headerTreeFuncName(for targetName: String) -> String {
        "headers\(sanitizedIdentifier(targetName))"
    }

    /// A C target's header tree on a module-tree port, keyed by the target's name.
    private func headerTreeWire(for targetName: String) -> String {
        "'\(targetName)': \(headerTreeFuncName(for: targetName))().files"
    }

    private func sliceFuncName(for targetName: String) -> String {
        "slice\(sanitizedIdentifier(targetName))"
    }

    /// A binary target's static library headers on a module-tree port, under the target's
    /// name as a C target's are; empty for a framework slice.
    private func binaryHeadersWire(for targetName: String) -> String {
        "'\(targetName)': TreeMerger(under: '\(targetName)', input: ['headers': \(sliceFuncName(for: targetName))().headers]).files"
    }

    // MARK: - Binary targets (B-77)

    /// The node choosing one binary target's slice for the platform being built, as a func
    /// the product funcs and the compilers of what reaches it name a port of. The platform
    /// is the Swift linker's settings' — the SDK and the triple the product is linked for —
    /// so the formula says nothing about it and one formula serves every platform.
    private func sliceFuncDef(target: SPMTarget, xcframework: String, rootPackageFolder: String) -> String {
        let configuration = Self.configurationExpression(namespace: SwiftLinkerConfiguration.settingNamespace,
                                                         packageFolder: buildRoot(defaultingTo: rootPackageFolder),
                                                         literals: [:])
        return "func \(sliceFuncName(for: target.name))() =\n" +
               "    XCFrameworkSliceSelector(\n" +
               "        path: '\(xcframework)',\n" +
               "        configuration: ['config': \(configuration)],\n" +
               "        infoPlist: ['Info.plist': StaticFile(path: '\(xcframework)/Info.plist').output]\n" +
               "    )"
    }

    private func sanitizedIdentifier(_ name: String) -> String {
        FormulaIdentifier.sanitized(name)
    }

    // MARK: - C targets (B-54, B-55)

    /// The folder holding a C target's public headers and its module map: the manifest's
    /// `publicHeadersPath`, or SwiftPM's `include`, when it exists; else the target folder.
    private func headerFolder(of target: SPMTarget, packageFolder: String) -> String {
        let folder = target.folder(in: target.overridePackageFolder ?? packageFolder)
        return PackageClangTarget.joined(folder, target.clangInfo?.publicHeadersPath ?? "")
    }

    /// What a C target with Objective-C in it tells both clang stages, as SwiftPM builds such
    /// a target (B-77): `modules` and `objectiveCARC`, and for the preprocessor the module
    /// the sources belong to, so its own headers stay text. Settings rather than flags,
    /// because the node decides per file what each means — ARC for Objective-C and
    /// Objective-C++, modules for Objective-C alone (`ClangLanguageFeatures`) — and
    /// literals, because like `moduleName` on the Swift side they say what the target is: a
    /// config file turning ARC off would make ARC code leak.
    ///
    /// Only a target with Objective-C, where SwiftPM enables modules for every C-family
    /// target but C++: split from its compile, a preprocessor with modules hands on text
    /// that imports again what it already expanded (B-55's residual 11).
    private func objectiveCLiterals(target: SPMTarget, includingModuleName: Bool) -> [String: String] {
        guard target.clangInfo?.hasObjectiveC == true else {
            return [:]
        }
        var literals = ["modules": "true", "objectiveCARC": "true"]
        if includingModuleName {
            literals["moduleName"] = target.moduleName
        }
        return literals
    }

    /// A C target's headers as the tree a Swift target importing it is given, under the
    /// target's name at their paths in its folder, with the module map in the public-headers
    /// folder — its own, or the one SwiftPM would write, from a `ModuleMapWriter` (B-55).
    /// The compiler puts every folder of the tree that holds a module map on its import
    /// path, which is the public-headers folder alone. Listed file by file rather than
    /// walked: the tree leaves out what `exclude:` names, and the converter already has the
    /// listing and runs again when it changes.
    ///
    /// ISSUE: a path holding a quote ends the formula's string, the limit every path here has.
    private func headerTreeFuncDef(target: SPMTarget, packageFolder: String) -> String {
        let folder = target.folder(in: target.overridePackageFolder ?? packageFolder)
        let clangInfo = target.clangInfo
        var entries = (clangInfo?.headerFiles ?? []).map { relative in
            "        '\(target.name)/\(relative)': StaticFile(path: '\(folder)/\(relative)').output"
        }
        if let publicHeaders = clangInfo?.publicHeadersPath, let moduleMap = clangInfo?.moduleMap {
            let mapPath = PackageClangTarget.joined(PackageClangTarget.joined(target.name, publicHeaders),
                                                    PackageClangTarget.moduleMapFileName)
            let umbrella: String? = switch moduleMap {
                case .provided:                    nil
                case .umbrellaHeader(let header):  "umbrellaHeader: '\(header)'"
                case .umbrellaDirectory:           "umbrellaDirectory: '.'"
            }
            if let umbrella {
                entries.append("        '\(mapPath)': ModuleMapWriter(moduleName: '\(target.moduleName)', \(umbrella)).output")
            }
        }
        return "func \(headerTreeFuncName(for: target.name))() =\n" +
               "    TreeBuilder(input: [" + (entries.isEmpty ? "" : "\n" + entries.sorted().joined(separator: ",\n") + "\n    ") + "]).files"
    }

    /// The preprocessor for one C target, as a func over the source path, the way the
    /// hand-written C formulas write it. Header folders: the target's own folder, its
    /// public headers, its `.headerSearchPath` folders, and the public headers of every C
    /// target it reaches — which is what SwiftPM puts on its search path. The preprocessor walks each folder to the bottom,
    /// so a header in a subfolder is where an `#include` beside it, or one under a search
    /// path, looks for it. The include finder is not used: these targets include by search
    /// path (`#include <parser.h>`), which it cannot resolve.
    ///
    /// The target's `.define` settings are the preprocessor's `defines`, a key of their
    /// own rather than `arguments`: a literal replaces the key it names in the settings it
    /// is laid over, so a define carried as `arguments` would drop the project's own
    /// `clang.preprocessor.arguments` for every target that has one. The compiler gets
    /// none: it reads preprocessed text, where no macro is left to define.
    ///
    /// ISSUE: a define whose value holds a comma splits in two, and one holding a quote
    /// ends the formula's string — the limit `sourcePaths` has on the Swift side.
    private func buildPreprocessorFuncDef(target: SPMTarget,
                                          packageFolder: String,
                                          lookupAll: (String) -> [SPMTarget]) -> String {
        let folder = target.folder(in: target.overridePackageFolder ?? packageFolder)
        var folders = [folder]
        let ownHeaders = headerFolder(of: target, packageFolder: packageFolder)
        if ownHeaders != folder {
            folders.append(ownHeaders)
        }
        for searchPath in target.clangInfo?.headerSearchPaths ?? [] {
            let searchFolder = PackageClangTarget.joined(folder, searchPath)
            if !folders.contains(searchFolder) { folders.append(searchFolder) }
        }
        for dependency in collectTransitiveClangTargets(root: target, lookupAll: lookupAll) {
            let dependencyHeaders = headerFolder(of: dependency, packageFolder: packageFolder)
            if !folders.contains(dependencyHeaders) { folders.append(dependencyHeaders) }
        }
        let folderWires = folders.map { "            '\($0)': Folder(path: '\($0)').manifest" }

        var literals = objectiveCLiterals(target: target, includingModuleName: true)
        if !target.cDefines.isEmpty {
            literals["defines"] = target.cDefines.joined(separator: ",")
        }
        let configExpr = Self.configurationExpression(namespace: Self.clangPreprocessorNamespace,
                                                      packageFolder: buildRoot(defaultingTo: packageFolder),
                                                      literals: literals)
        return "func \(preprocessorFuncName(for: target.name))(path) =\n" +
               "    ClangPreprocessor(\n" +
               "        configuration: ['config': \(configExpr)],\n" +
               "        input: [path: StaticFile(path: path)],\n" +
               "        headerFolders: [\n" + folderWires.joined(separator: ",\n") + "\n        ]\n" +
               "    )"
    }

    /// The linker's object entries for one C target: one for-each over the target's
    /// sources at any depth — a `**/*.<ext>` per extension its tree holds — less what its
    /// `exclude:` names, compiling each preprocessed file. The patterns are plain strings,
    /// so the generated text needs no path literal.
    private func clangObjectEntries(target: SPMTarget, packageFolder: String) -> [String] {
        guard let clangInfo = target.clangInfo else {
            return []
        }
        let folder = target.folder(in: target.overridePackageFolder ?? packageFolder)
        let configExpr = Self.configurationExpression(namespace: Self.clangCompilerNamespace,
                                                      packageFolder: buildRoot(defaultingTo: packageFolder),
                                                      literals: objectiveCLiterals(target: target, includingModuleName: false))
        func quoted(_ relative: String) -> String { "'\(folder)/\(relative)'" }
        func items(_ patterns: [String]) -> String {
            var items = patterns.map(quoted).joined(separator: ", ")
            if !clangInfo.excludedPatterns.isEmpty {
                items += " except " + clangInfo.excludedPatterns.map(quoted).joined(separator: ", ")
            }
            return items
        }
        var entries: [String] = []
        if !clangInfo.sourcePatterns.isEmpty {
            entries.append("        {f: \(items(clangInfo.sourcePatterns))} \"%%f%%.o\": ClangCompiler(" +
                           "configuration: ['config': \(configExpr)], " +
                           "input: [\"%%f%%.p\": \(preprocessorFuncName(for: target.name))(path: f)])")
        }
        // A `.s` has no preprocessing phase, so the compiler takes the file itself (B-55).
        if !clangInfo.assemblyPatterns.isEmpty {
            entries.append("        {f: \(items(clangInfo.assemblyPatterns))} \"%%f%%.o\": ClangCompiler(" +
                           "configuration: ['config': \(configExpr)], " +
                           "input: [\"%%f%%\": StaticFile(path: f)])")
        }
        return entries
    }

    // Emits a zero-parameter func definition for one compiler node.
    // For external targets, `overridePackageFolder` replaces `packageFolder` as
    // the root from which `sourcesRelativePath` is resolved.
    private func buildFuncDef(target: SPMTarget,
                              packageFolder: String,
                              lookupAll: (String) -> [SPMTarget],
                              binaryTargets: [SPMTarget] = []) -> String {
        let pkgRoot     = target.overridePackageFolder ?? packageFolder
        let sourcesPath = target.folder(in: pkgRoot)
        // moduleName is what makes a target itself, and a config file must not be able to
        // rename it -- so it is a literal property, which is what makes it win over the file.
        var derived = ["moduleName": target.moduleName]
        if target.type == "executable" {
            derived["parseAsLibrary"] = "false"
        }
        // A target with resources compiles with the `Bundle.module` accessor SwiftPM
        // would generate, naming the bundle `resourceBundleFuncDef` builds (B-77).
        if !target.resources.isEmpty {
            derived["resourceBundleName"] = target.resourceBundleName
        }
        // Like moduleName, a fact about the target: dropped, the code compiles in Swift 5
        // mode with different diagnostics, and a config file must not be able to change it.
        if let languageMode = target.languageMode {
            derived["languageMode"] = languageMode
        }
        // Comma-joined because a configuration value is one line of `key=value` and so
        // cannot hold a newline. A path containing a comma would break this, as would one
        // containing a quote — which the formula lexer has never handled for any value.
        if !target.sources.isEmpty {
            derived["sourcePaths"] = target.sources.joined(separator: ",")
        }
        if !target.exclude.isEmpty {
            derived["excludedPaths"] = target.exclude.joined(separator: ",")
        }

        // The root package's own folder, not `pkgRoot`: configuration is a property of the
        // build, not of whichever package happens to be compiled, and a consuming project
        // cannot write a config file inside a vendored dependency it does not own.
        let configExpr = Self.configurationExpression(namespace: SwiftCompilerConfiguration.settingNamespace,
                                                      packageFolder: buildRoot(defaultingTo: packageFolder),
                                                      literals: derived)
        let folderExpr  = "Folder(path: '\(sourcesPath)').manifest"

        // Every transitively reachable Swift target, not just the direct dependencies.
        // A binary .swiftmodule records the modules it was built against, and swiftc must
        // load all of them to load it: compiling SemelCLI, which imports only
        // SemelCore, fails with "missing required modules: 'SemelDatabaseModels', 'GRDB'"
        // unless those are on its import path too.
        var moduleWires: [String] = []
        for depTarget in collectTransitiveTargets(root: target, lookupAll: lookupAll)
        where depTarget.name != target.name {
            // Named for the module, not the target: the compiler writes the wire's name
            // plus `.swiftmodule`, and swiftc looks for the file under the module's name.
            let fn = compilerFuncName(for: depTarget.name)
            moduleWires.append("            '\(depTarget.moduleName)': \(fn)().swiftmodule")
        }

        // System libraries, by contrast, must reach every target that imports them
        // *transitively*.  A .swiftmodule records the Clang modules it was built against,
        // so loading GRDB.swiftmodule without GRDBSQLite's module.modulemap on the import
        // path fails with "missing required module 'GRDBSQLite'" — in a target that never
        // names GRDBSQLite itself.
        var moduleMapFolderWires: [String] = []
        for systemLibrary in collectTransitiveSystemLibraries(root: target, lookupAll: lookupAll) {
            // Place the module.modulemap directory into the sandbox so swiftc can
            // resolve the system module.
            let depPkgRoot    = systemLibrary.overridePackageFolder ?? packageFolder
            let mapFolderPath = systemLibrary.folder(in: depPkgRoot)
            moduleMapFolderWires.append("            '\(systemLibrary.name)': Folder(path: '\(mapFolderPath)').manifest")
        }
        // A C target reached the same way is importable through its header tree, the module
        // map in it its own or the one SwiftPM would write (B-54, B-55): the same value a
        // product's module tree carries it in, so an app importing the product and a target
        // beside it in the package import one module.
        // A binary target reached the same way is its slice (B-77): a framework on the
        // framework search path, a static library's headers on the import path.
        let moduleTreeWires = collectTransitiveClangTargets(root: target, lookupAll: lookupAll).map {
            "            " + headerTreeWire(for: $0.name)
        } + binaryTargets.map {
            "            " + binaryHeadersWire(for: $0.name)
        }
        let frameworkTreeWires = binaryTargets.map {
            "            '\($0.name)': \(sliceFuncName(for: $0.name))().frameworks"
        }

        var args =
            "    configuration: ['config': \(configExpr)],\n" +
            "    inputFolder: ['folder0': \(folderExpr)]"
        if !moduleWires.isEmpty {
            args += ",\n    inputModules: [\n" + moduleWires.joined(separator: ",\n") + "\n    ]"
        }
        if !moduleTreeWires.isEmpty {
            args += ",\n    moduleTrees: [\n" + moduleTreeWires.joined(separator: ",\n") + "\n    ]"
        }
        if !frameworkTreeWires.isEmpty {
            args += ",\n    frameworkTrees: [\n" + frameworkTreeWires.joined(separator: ",\n") + "\n    ]"
        }
        if !moduleMapFolderWires.isEmpty {
            args += ",\n    inputModuleMapFolders: [\n" + moduleMapFolderWires.joined(separator: ",\n") + "\n    ]"
        }
        return "func \(compilerFuncName(for: target.name))() =\n    SwiftCompiler(\n\(args)\n    )"
    }

    /// The func carrying one target's resource bundle as a tree, every piece under
    /// `<Package>_<Target>.bundle/` (B-77): a catalog through the asset compiler, a string
    /// catalog through its compiler, an `.lproj` or a copied folder as the folder it is,
    /// and every copied file in one tree. The Apple compilers select their settings from
    /// the root's config, as the Swift tools do.
    private func resourceBundleFuncDef(target: SPMTarget, rootPackageFolder: String) -> String {
        let pkgRoot      = target.overridePackageFolder ?? rootPackageFolder
        let targetFolder = target.folder(in: pkgRoot)
        let configRoot   = buildRoot(defaultingTo: rootPackageFolder)
        var wires: [String] = []
        var copiedFiles: [String] = []
        for (index, resource) in target.resources.enumerated() {
            let fullPath = PackageResources.fullPath(targetFolder: targetFolder, relative: resource.path)
            let name     = (resource.path as NSString).lastPathComponent
            switch resource.kind {
            case .assetCatalog:
                let configuration = Self.configurationExpression(namespace: Self.assetCatalogCompilerNamespace,
                                                                 packageFolder: configRoot, literals: [:])
                wires.append("        'r\(index)': AssetCatalogCompiler(configuration: ['config': \(configuration)], "
                           + "catalogs: ['\(name)': Folder(path: '\(fullPath)').manifest]).files")
            case .stringCatalog:
                let configuration = Self.configurationExpression(namespace: Self.stringCatalogCompilerNamespace,
                                                                 packageFolder: configRoot, literals: [:])
                wires.append("        'r\(index)': StringCatalogCompiler(configuration: ['config': \(configuration)], "
                           + "catalog: ['\(name)': StaticFile(path: '\(fullPath)').output]).files")
            case .localizedFolder, .folder:
                wires.append("        'r\(index)': FolderTreeBuilder(under: '\(resource.bundlePath)', "
                           + "folder: ['folder': Folder(path: '\(fullPath)').manifest]).files")
            case .file:
                copiedFiles.append("            '\(resource.bundlePath)': StaticFile(path: '\(fullPath)').output")
            }
        }
        if !copiedFiles.isEmpty {
            wires.append("        'files': TreeBuilder(input: [\n" + copiedFiles.joined(separator: ",\n") + "\n        ]).files")
        }
        return "func \(FormulaIdentifier.bundleFunc(forTarget: target.name))() =\n" +
               "    TreeMerger(under: '\(target.resourceBundleName).bundle', input: [\n" +
               wires.joined(separator: ",\n") + "\n" +
               "    ]).files"
    }

    // Resolves a relative path (which may contain "..") against a base path.
    // Both paths are virtual input-filesystem paths, not real filesystem paths. A path
    // that climbs above the file system comes back empty, which the caller skips as it
    // skips any path outside the input file system.
    private func resolveRelativePath(_ relative: String, from base: String) -> String {
        (Path(base) / Path(relative)).resolvingDotSegments?.string ?? ""
    }
}
