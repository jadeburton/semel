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
    /// content root of every vendored package, and a mismatch is its error (B-06).
    public static let implementationVersion = 6

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
            return try pendingOutput(reason: "SwiftFormulaConverter: waiting for the package folder and manifest",
                                     externalSpecs: [:])
        }

        // ── packageFolder ─────────────────────────────────────────────────────
        let manifestJSON = try folderValue.expectValue().resolveAsString()

        guard let folderManifest = try? TypeRegistry.decode(encodedJSON: manifestJSON) as? FolderManifest else {
            return try pendingOutput(reason: "SwiftFormulaConverter: could not decode FolderManifest",
                                     externalSpecs: [:])
        }

        let rootPackageFolder = folderManifest.baseFolderPath

        // ── root packageJSON ──────────────────────────────────────────────────
        let jsonEntry = try jsonValue.expectValue()

        let rootManifest: SPMManifest

        do {
            rootManifest = try SPMManifest.decode(try jsonEntry.resolveAsString())
        } catch {
            return try pendingOutput(reason: "SwiftFormulaConverter: \(error)", externalSpecs: [:])
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
        let lockDemands = LockDemands(locks: lockCheck.lockSpecs,
                                      contentRoots: lockCheck.contentRootSpecs(locks: lockValues))

        // ── wait until every expected manifest has been received ──────────────
        let missing = specs.keys.filter { availableManifests[$0] == nil }

        guard missing.isEmpty else {
            return try pendingOutput(
                reason: describeStall(missingPaths: missing.sorted(), origins: originOfExpectedPath),
                externalSpecs: specs,
                lockDemands: lockDemands,
                awaitedPackageFolderSpecs: Dictionary(uniqueKeysWithValues: missing.map { ($0, .folderManifest(at: $0)) }))
        }

        // ── every lock compared with its package's content root ───────────────
        let unlockedFolders: [String]
        switch try lockCheck.outcome(locks: lockValues,
                                     contentRoots: input.inputValues[Self.dependencyContentRoots] ?? [:]) {
        case .waiting(let folders):
            return try pendingOutput(
                reason: "SwiftFormulaConverter: waiting for the lock of \(folders.count) vendored package(s):\n"
                      + folders.map { "  \($0)" }.joined(separator: "\n"),
                externalSpecs: specs,
                lockDemands: lockDemands)
        case .failed(let problems):
            return try pendingOutput(
                reason: "SwiftFormulaConverter: " + problems.map(\.description).joined(separator: "\n\n"),
                externalSpecs: specs,
                lockDemands: lockDemands)
        case .passed(let unlocked):
            unlockedFolders = unlocked
        }

        // ── every compilable target's folder, to tell C targets from Swift ones ──
        // A manifest says nothing about a target's language; its folder does. The
        // folders are asked for once every manifest is in, so this is one more pass.
        var targetFolderSpecs: [String: GraphSpecNode] = [:]
        for (packageFolder, manifest) in [(rootPackageFolder, rootManifest)] + availableManifests.sorted(by: { $0.key < $1.key }) {
            for target in manifest.targets where target.isCompilable {
                let folder = "\(packageFolder)/\(target.sourcesRelativePath)"
                targetFolderSpecs[folder] = .folderManifest(at: folder)
            }
        }

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
                externalSpecs: specs,
                lockDemands: lockDemands,
                targetFolderSpecs: targetFolderSpecs)
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
        let missingSubfolders = subfolderSpecs.keys.filter { folderManifests[$0] == nil }.sorted()
        guard missingSubfolders.isEmpty else {
            return try pendingOutput(
                reason: "SwiftFormulaConverter: walking \(missingSubfolders.count) target subfolder(s) for resources",
                externalSpecs: specs,
                lockDemands: lockDemands,
                targetFolderSpecs: targetFolderSpecs,
                targetSubfolderSpecs: subfolderSpecs)
        }

        // ── all manifests present — generate formula ──────────────────────────
        let formula = generateFormula(rootManifest: rootManifest,
                                      externalManifests: availableManifests,
                                      rootPackageFolder: rootPackageFolder,
                                      clangInfo: { target, folder in
                                          PackageClangTarget(targetFolder: folder, rules: target.clangRules,
                                                             manifests: folderManifests)
                                      },
                                      resources: { target, folder in
                                          PackageResources.detect(rules: target.resourceRules, targetFolder: folder,
                                                                  manifests: folderManifests)
                                      })
        // Said once the formula is made, not on the passes that wait for it, so a
        // conversion says it once.
        if !unlockedFolders.isEmpty {
            NodeNotice.post(DependencyLockCheck.notice(unlocked: unlockedFolders))
        }
        return .init(
            outputValues: [Self.formulaOutput: .value(try formula.intern()),
                           Self.infoLog: .value("")],
            inputWireSpecs: selfWiringSpecs.merging([Self.externalPackageJSONs: specs,
                                                     Self.dependencyLocks: lockDemands.locks,
                                                     Self.dependencyContentRoots: lockDemands.contentRoots,
                                                     Self.targetFolders: targetFolderSpecs,
                                                     Self.targetSubfolders: subfolderSpecs,
                                                     Self.awaitedPackageFolders: [:]]) { _, new in new })
    }

    /// The wires the lock check asks for on every pass, whatever the pass is waiting on:
    /// a spec left out of an output is unwired.
    private struct LockDemands {
        var locks:        [String: GraphSpecNode] = [:]
        var contentRoots: [String: GraphSpecNode] = [:]
    }

    // Returns a noValue output that still carries the current specs — the node's own
    // package wires included, since a spec left out of any output is unwired — so
    // applySpecs keeps (or creates) the needed wires.
    private func pendingOutput(reason: String,
                               externalSpecs: [String: GraphSpecNode],
                               lockDemands: LockDemands = LockDemands(),
                               targetFolderSpecs: [String: GraphSpecNode] = [:],
                               targetSubfolderSpecs: [String: GraphSpecNode] = [:],
                               awaitedPackageFolderSpecs: [String: GraphSpecNode] = [:]) throws -> ProcessOutput {
        .init(outputValues: [Self.formulaOutput: .noValue(reason: .error(messageDataObjectHash: try reason.intern())),
                             Self.infoLog: .value("")],
              inputWireSpecs: selfWiringSpecs.merging([Self.externalPackageJSONs: externalSpecs,
                                                       Self.dependencyLocks: lockDemands.locks,
                                                       Self.dependencyContentRoots: lockDemands.contentRoots,
                                                       Self.targetFolders: targetFolderSpecs,
                                                       Self.targetSubfolders: targetSubfolderSpecs,
                                                       Self.awaitedPackageFolders: awaitedPackageFolderSpecs]) { _, new in new })
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
        /// platform and configuration being built, which nothing here decides per target yet.
        let cDefines: [String]
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
            .init(sources: sources, exclude: exclude, publicHeadersPath: publicHeadersPath)
        }

        var isClangTarget: Bool { clangInfo != nil }

        /// Whether a build compiles this target at all: not a test, a system library, a
        /// plugin or a macro.
        var isCompilable: Bool {
            !isSystemLibrary && !["test", "plugin", "macro"].contains(type ?? "")
        }

        enum CodingKeys: String, CodingKey {
            case name, type, path, dependencies, sources, exclude, settings, resources, publicHeadersPath
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

            enum CodingKeys: String, CodingKey { case kind, tool, condition }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                kind          = try? container.decode([String: [String: String]].self, forKey: .kind)
                tool          = try? container.decode(String.self, forKey: .tool)
                isConditional = container.contains(.condition) && !((try? container.decodeNil(forKey: .condition)) ?? false)
            }

            /// The value of an unconditional `.define` for C or C++, as written.
            var unconditionalDefine: String? {
                guard !isConditional, ["c", "cxx"].contains(tool ?? "") else {
                    return nil
                }
                return kind?["define"]?["_0"]
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
            publicHeadersPath = try? c.decode(String.self, forKey: .publicHeadersPath)
            overridePackageFolder = nil
        }

        // SPM default: Sources/<TargetName> relative to the package root.
        var sourcesRelativePath: String { path ?? "Sources/\(name)" }

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
                                 clangInfo: (SPMTarget, String) -> PackageClangTarget?,
                                 resources: (SPMTarget, String) -> [PackageResource] = { _, _ in [] }) -> String {
        // Every lookup below walks the external packages in one fixed order. Dictionary
        // iteration order is seeded per process, so walking the dictionary itself let two
        // packages vending the same name resolve differently on every restart — and the
        // formula text is what every downstream graphSpec is derived from.
        let externalPackages = externalManifests.sorted { $0.key < $1.key }

        // A target with its package folder, what its own folder says about its language,
        // and the resources its folder holds (B-77), which is what every walk below asks.
        func placed(_ target: SPMTarget, in packageFolder: String?) -> SPMTarget {
            var placed = target
            let folder = "\(packageFolder ?? rootPackageFolder)/\(target.sourcesRelativePath)"
            placed.overridePackageFolder = packageFolder
            placed.packageName = packageFolder.flatMap { externalManifests[$0]?.name } ?? rootManifest.name
            placed.clangInfo = clangInfo(target, folder)
            placed.resources = placed.isClangTarget ? [] : resources(placed, folder)
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

        for product in productsToBuild(in: rootManifest) {

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
            guard !allTargets.isEmpty || !clangTargets.isEmpty else { continue }

            // Emit one func definition per unique target (shared across products).
            for target in allTargets {
                let fn = compilerFuncName(for: target.name)
                guard !emittedFuncs.contains(fn) else { continue }
                blocks.append(buildFuncDef(target: target,
                                           packageFolder: rootPackageFolder,
                                           lookupAll: allTargetsNamed))
                emittedFuncs.insert(fn)
            }

            // Each target's resource bundle, once, and the product's tree of them (B-77):
            // emitted for every product, empty or not, so an app can name it without
            // knowing which targets carry resources.
            var bundleWires: [String] = []
            for target in allTargets where !target.resources.isEmpty {
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
            let linkerConfig = Self.configurationExpression(
                namespace: SwiftLinkerConfiguration.settingNamespace,
                packageFolder: buildRoot(defaultingTo: rootPackageFolder),
                literals: ["linkage":    linkage.rawValue,
                           "outputName": outputName])

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
                    let folderPath     = "\(libraryPkgRoot)/\(systemLibrary.sourcesRelativePath)"
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
            // and system library the product reaches travels in the same tree, its header
            // folder under the target's name.
            var moduleMapTrees: [String] = []
            var wiredModuleMaps = Set<String>()
            for target in allTargets {
                for systemLibrary in collectTransitiveSystemLibraries(root: target, lookupAll: allTargetsNamed)
                where wiredModuleMaps.insert(systemLibrary.name).inserted {
                    let folder = "\(systemLibrary.overridePackageFolder ?? rootPackageFolder)/\(systemLibrary.sourcesRelativePath)"
                    moduleMapTrees.append(Self.folderTreeWire(name: systemLibrary.name, folder: folder))
                }
                for clangTarget in collectTransitiveClangTargets(root: target, lookupAll: allTargetsNamed)
                where wiredModuleMaps.insert(clangTarget.name).inserted {
                    moduleMapTrees.append(Self.folderTreeWire(name: clangTarget.name,
                                                              folder: headerFolder(of: clangTarget, packageFolder: rootPackageFolder)))
                }
            }
            // And a C target no Swift one reaches: the product's own, for whoever imports it.
            for clangTarget in clangTargets where wiredModuleMaps.insert(clangTarget.name).inserted {
                moduleMapTrees.append(Self.folderTreeWire(name: clangTarget.name,
                                                          folder: headerFolder(of: clangTarget, packageFolder: rootPackageFolder)))
            }
            let swiftModulesTree = "'swift': TreeBuilder(input: [\n" + moduleWires.joined(separator: ",\n") + "\n        ]).files"
            blocks.append(
                "func \(FormulaIdentifier.modulesFunc(forProduct: product.name))() =\n" +
                "    TreeMerger(input: [\n" +
                "        " + ([swiftModulesTree] + moduleMapTrees).joined(separator: ",\n        ") + "\n" +
                "    ]).files")
            blocks.append(
                "func \(FormulaIdentifier.objectsFunc(forProduct: product.name))() =\n" +
                "    TreeBuilder(input: [\n" +
                objectWires.joined(separator: ",\n") + "\n" +
                "    ]).files")

            let block =
                "product '\(outputName)' =\n" +
                "    SwiftLinker(\n" +
                linkerArgs + "\n" +
                "    ).output"
            blocks.append(block)
        }

        return blocks.joined(separator: "\n\n")
    }

    /// One folder of headers and a module map as a tree under `name`, for a product's
    /// module tree: `'CAtomic': FolderTreeBuilder(under: 'CAtomic', folder: [...]).files`.
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
            // none either: its objects come through the clang nodes and its include
            // folder reaches Swift the same way a system library's does.
            guard !target.isSystemLibrary, !target.isClangTarget else {
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

    private func sanitizedIdentifier(_ name: String) -> String {
        FormulaIdentifier.sanitized(name)
    }

    // MARK: - C targets (B-54, B-55)

    /// The folder holding a C target's public headers and its module map: the manifest's
    /// `publicHeadersPath`, or SwiftPM's `include`, when it exists; else the target folder.
    private func headerFolder(of target: SPMTarget, packageFolder: String) -> String {
        let folder = "\(target.overridePackageFolder ?? packageFolder)/\(target.sourcesRelativePath)"
        return PackageClangTarget.joined(folder, target.clangInfo?.publicHeadersPath ?? "")
    }

    /// The preprocessor for one C target, as a func over the source path, the way the
    /// hand-written C formulas write it. Header folders: the target's own folder, its
    /// public headers, and the public headers of every C target it reaches — which is what
    /// SwiftPM puts on its search path. The preprocessor walks each folder to the bottom,
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
        let folder = "\(target.overridePackageFolder ?? packageFolder)/\(target.sourcesRelativePath)"
        var folders = [folder]
        let ownHeaders = headerFolder(of: target, packageFolder: packageFolder)
        if ownHeaders != folder {
            folders.append(ownHeaders)
        }
        for dependency in collectTransitiveClangTargets(root: target, lookupAll: lookupAll) {
            let dependencyHeaders = headerFolder(of: dependency, packageFolder: packageFolder)
            if !folders.contains(dependencyHeaders) { folders.append(dependencyHeaders) }
        }
        let folderWires = folders.map { "            '\($0)': Folder(path: '\($0)').manifest" }

        let literals = target.cDefines.isEmpty ? [:] : ["defines": target.cDefines.joined(separator: ",")]
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
        let folder = "\(target.overridePackageFolder ?? packageFolder)/\(target.sourcesRelativePath)"
        let configExpr = Self.configurationExpression(namespace: Self.clangCompilerNamespace,
                                                      packageFolder: buildRoot(defaultingTo: packageFolder),
                                                      literals: [:])
        func quoted(_ relative: String) -> String { "'\(folder)/\(relative)'" }
        var items = clangInfo.sourcePatterns.map(quoted).joined(separator: ", ")
        if !clangInfo.excludedPatterns.isEmpty {
            items += " except " + clangInfo.excludedPatterns.map(quoted).joined(separator: ", ")
        }
        return ["        {f: \(items)} \"%%f%%.o\": ClangCompiler(" +
                "configuration: ['config': \(configExpr)], " +
                "input: [\"%%f%%.p\": \(preprocessorFuncName(for: target.name))(path: f)])"]
    }

    // Emits a zero-parameter func definition for one compiler node.
    // For external targets, `overridePackageFolder` replaces `packageFolder` as
    // the root from which `sourcesRelativePath` is resolved.
    private func buildFuncDef(target: SPMTarget,
                              packageFolder: String,
                              lookupAll: (String) -> [SPMTarget]) -> String {
        let pkgRoot     = target.overridePackageFolder ?? packageFolder
        let sourcesPath = "\(pkgRoot)/\(target.sourcesRelativePath)"
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
            let mapFolderPath = "\(depPkgRoot)/\(systemLibrary.sourcesRelativePath)"
            moduleMapFolderWires.append("            '\(systemLibrary.name)': Folder(path: '\(mapFolderPath)').manifest")
        }
        // A C target reached the same way is importable through the module map in its
        // public-headers folder, exactly like a system library (B-54).
        for clangTarget in collectTransitiveClangTargets(root: target, lookupAll: lookupAll) {
            let mapFolderPath = headerFolder(of: clangTarget, packageFolder: packageFolder)
            moduleMapFolderWires.append("            '\(clangTarget.name)': Folder(path: '\(mapFolderPath)').manifest")
        }

        var args =
            "    configuration: ['config': \(configExpr)],\n" +
            "    inputFolder: ['folder0': \(folderExpr)]"
        if !moduleWires.isEmpty {
            args += ",\n    inputModules: [\n" + moduleWires.joined(separator: ",\n") + "\n    ]"
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
        let targetFolder = "\(pkgRoot)/\(target.sourcesRelativePath)"
        let configRoot   = buildRoot(defaultingTo: rootPackageFolder)
        var wires: [String] = []
        var copiedFiles: [String] = []
        for (index, resource) in target.resources.enumerated() {
            let fullPath = "\(targetFolder)/\(resource.path)"
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
