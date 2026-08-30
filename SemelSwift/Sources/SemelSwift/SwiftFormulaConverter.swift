// SwiftFormulaConverter.swift
// SemelCore
//
// Converts a `swift package dump-package` JSON manifest into a .fmla formula
// string that ProjectBuilder can consume as its projectFile input.
//
// Wire topology:
//   Folder(path: 'input:/.../MyPkg').manifest -> SwiftFormulaConverter.packageFolder
//   SwiftPackageReaderTool.packageJSON                 -> SwiftFormulaConverter.packageJSON
//   SwiftFormulaConverter.formula                      -> ProjectBuilder.projectFile
//
// `packageFolder` is wired to a Folder.manifest rather than stored as a
// property so the node re-runs whenever files are added to or removed from the
// package root (e.g. a new Sources/NewTarget directory appears). The package
// path is read from FolderManifest.baseFolderPath at process time.
//
// External package dependencies are resolved iteratively via the dynamic
// `externalPackageJSONs` port.  After parsing the root Package.swift the node
// returns SwiftPackageReaderTool wire expectations for each fileSystem dep it
// finds; when those manifests arrive the process repeats for their own deps,
// and so on until the full transitive closure is wired.  Packages no longer
// referenced are automatically unwired by applyExpectationConfiguration.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

struct SwiftFormulaConverter: NodeFunction {
    public static let kind: UInt = 24

    static let packageFolder        = "packageFolder"
    static let packageJSON          = "packageJSON"
    static let formulaOutput        = "formula"
    static let infoLog              = "infoLog"
    static let externalPackageJSONs = "externalPackageJSONs"

    public var thisNode: Node

    public init(thisNode: Node) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeFunctionDescriptor(
        inputPorts: [
            .required(packageFolder),
            .required(packageJSON),
            .dynamic(externalPackageJSONs),
        ],
        outputPorts: [formulaOutput, infoLog]
    )

    // MARK: - Processing

    public func process(input: ProcessInput) throws -> ProcessOutput {

        // ── packageFolder ─────────────────────────────────────────────────────
        let manifestJSON = try input.inputValues[Self.packageFolder]!.values.first!.expectValue().resolveAsString()

        guard let folderManifest = try? PolyFactory.decode(encodedJSON: manifestJSON) as? FolderManifest else {
            return try pendingOutput(reason: "SwiftFormulaConverter: could not decode FolderManifest",
                                 externalExpectations: [:])
        }

        let rootPackageFolder = folderManifest.baseFolderPath

        // ── root packageJSON ──────────────────────────────────────────────────
        let jsonEntry = try input.inputValues[Self.packageJSON]!.values.first!.expectValue()

        let rootManifest: SPMManifest

        do {
            rootManifest = try SPMManifest.decode(try jsonEntry.resolveAsString())
        } catch {
            return try pendingOutput(reason: "SwiftFormulaConverter: \(error)", externalExpectations: [:])
        }

        // ── already-received external manifests ───────────────────────────────
        // Wire key = resolved input-filesystem path of the external package root.
        var availableManifests: [String: SPMManifest] = [:]
        for (extPath, nodeValue) in input.inputValues[Self.externalPackageJSONs] ?? [:] {
            guard let jsonStr  = try? nodeValue.expectValue().resolveAsString(),
                  let manifest = try? SPMManifest.decode(jsonStr) else { continue }
            availableManifests[extPath] = manifest
        }

        // ── BFS: discover all transitively needed external packages ───────────
        // Each run reaches one more nesting level; missing manifests are requested
        // via wire expectations and the node is re-scheduled when they arrive.
        var bfsQueue: [(path: String, manifest: SPMManifest)] = [(rootPackageFolder, rootManifest)]
        var visitedPaths = Set<String>([rootPackageFolder])
        var expectations: [String: String] = [:]
        // Path -> repository URL it stands for, nil when the manifest named the path
        // itself. Only ever read to explain a stall.
        var originOfExpectedPath: [String: String?] = [:]
        var bfsIndex = 0

        while bfsIndex < bfsQueue.count {
            let (manifestPath, manifest) = bfsQueue[bfsIndex]; bfsIndex += 1
            for dependency in manifest.packageDependencies {
                // Resolved against the manifest that declared it, not the root: a vendored
                // checkout sits beside whichever package named it, and that package may
                // itself be an external one several levels down.
                let extPath = resolveRelativePath(dependency.path, from: manifestPath)
                // Skip dependencies whose resolved path falls outside the virtual
                // inputFileSystem — they are system-level or truly external packages
                // that cannot be read through the build graph.
                guard extPath.hasPrefix(FileSystemName.input + "/") else { continue }
                guard !visitedPaths.contains(extPath) else { continue }
                visitedPaths.insert(extPath)
                expectations[extPath] = packageReaderExpectation(for: extPath)
                originOfExpectedPath[extPath] = dependency.repositoryURL
                if let extManifest = availableManifests[extPath] {
                    bfsQueue.append((extPath, extManifest))
                }
            }
        }

        // ── wait until every expected manifest has been received ──────────────
        let missing = expectations.keys.filter { availableManifests[$0] == nil }
        guard missing.isEmpty else {
            return try pendingOutput(
                reason: describeStall(missingPaths: missing.sorted(), origins: originOfExpectedPath),
                externalExpectations: expectations)
        }

        // ── all manifests present — generate formula ──────────────────────────
        let formula = generateFormula(rootManifest: rootManifest,
                                      externalManifests: availableManifests,
                                      rootPackageFolder: rootPackageFolder)
        return .init(
            outputValues: [Self.formulaOutput: .value(try formula.intern()),
                           Self.infoLog:       .value("")],
            inputWireExpectations: [Self.externalPackageJSONs: expectations])
    }

    // Returns a noValue output that still carries the current expectations,
    // so applyExpectationConfiguration keeps (or creates) the needed wires.
    private func pendingOutput(reason: String,
                               externalExpectations: [String: String]) throws -> ProcessOutput {
        .init(outputValues: [Self.formulaOutput: .noValue(reason: .error(messageDataObjectHash: try reason.intern())),
                             Self.infoLog:       .value("")],
              inputWireExpectations: [Self.externalPackageJSONs: externalExpectations])
    }

    // MARK: - semel.config

    /// The file name a selector looks for beside a package: `semel.config`.
    static let configFileName = "semel.config"

    /// Explains a stall in terms the user can act on.
    ///
    /// The old text named only the paths being waited on, which is the least useful part:
    /// for a git dependency that path is a *convention this build system invented*, so a
    /// user seeing `input:/repo/GRDB.swift` had no way to connect it to the
    /// `.package(url:)` line in their manifest, and no hint that nothing was ever going to
    /// arrive on its own.
    private func describeStall(missingPaths: [String], origins: [String: String?]) -> String {
        let lines = missingPaths.map { path -> String in
            guard let url = origins[path] ?? nil else {
                return "  \(path) — declared as a local path dependency, but nothing is there"
            }
            return "  \(path) — where \(url) is expected to be vendored"
        }

        return "SwiftFormulaConverter: waiting for \(missingPaths.count) package(s):\n"
             + lines.joined(separator: "\n")
             + "\nThis build system never fetches anything: a dependency must be present in "
             + "the input file system at the path above, pushed like any other source."
    }

    // Graph-shape expectation string for a SwiftPackageReaderTool that reads
    // the Package.swift at `extPath` in the input filesystem.
    private func packageReaderExpectation(for extPath: String) -> String {
        let pkgFilePath = "\(extPath)/Package.swift"
        return "SwiftPackageReaderTool(" +
               "configuration: ['config': Configuration().output], " +
               "packageFile: ['\(pkgFilePath)': StaticFile(path: '\(pkgFilePath)').output]" +
               ").packageJSON"
    }

    /// The config file a package is configured by: `semel.config` beside the package.
    ///
    /// Named in the shape rather than looked up, so the wire exists before the file does — an
    /// absent file is a ghost, and pushing it later fills the wire and rebuilds what depends on
    /// it without a rescan.
    private func configSelector(namespace: String, packageFolder: String) -> String {
        let configPath = "\(packageFolder)/\(Self.configFileName)"
        return "ConfigSubset(prefix: '\(namespace)', "
             + "input: ['config': StaticFile(path: '\(configPath)').output]).output"
    }

    /// Renders a `Configuration(...)` whose `inherit` port carries the selector for
    /// `namespace`, with `literals` overlaid as properties.
    ///
    /// Properties win over the file: `literals` is manifest-derived — `moduleName`,
    /// `dynamicLibrary` and the like — so it describes what the target *is*, and a config
    /// file must not be able to override identity through the settings it supplies.
    ///
    /// Sorted, because these become a formula string that becomes a node's searchKey — and
    /// Dictionary iteration order is seeded per process, so an unsorted render would give
    /// the same package a different node identity on every run.
    private func configurationExpression(namespace: String,
                                         packageFolder: String,
                                         literals: [String: String]) -> String {
        let rendered = literals.sorted { $0.key < $1.key }
                               .map { "\($0.key): '\($0.value)'" }
                               .joined(separator: ", ")
        let selector = configSelector(namespace: namespace, packageFolder: packageFolder)
        let arguments = rendered.isEmpty ? "" : "\(rendered), "
        return "Configuration(\(arguments)inherit: ['settings': \(selector)]).output"
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
            let c        = try decoder.container(keyedBy: CodingKeys.self)
            name         = try c.decode(String.self,      forKey: .name)
            targets      = try c.decode([SPMTarget].self,  forKey: .targets)
            products     = try c.decode([SPMProduct].self, forKey: .products)
            let rawDeps  = (try? c.decode([AnySPMDependency].self, forKey: .dependencies)) ?? []
            packageDependencies = rawDeps.flatMap { $0.dependencies }
        }

        static func decode(_ json: String) throws -> SPMManifest {
            try JSONDecoder().decode(SPMManifest.self, from: Data(json.utf8))
        }
    }

    // Decodes one element of the top-level "dependencies" array down to local paths.
    //
    // fileSystem entries carry their path directly.  sourceControl entries name a git
    // URL, which this build system never fetches — every input must come through the
    // graph — so the repository is expected to be *vendored* into the input filesystem
    // beside the package that depends on it, and resolves to "../<RepositoryName>".
    //
    // ISSUE: a sourceControl dependency's version requirement is not checked against the
    // vendored copy.  Nothing here can read a version out of a bare source tree, so a
    // manifest asking for `from: "7.11.1"` builds against whatever happens to be vendored.
    // Enforcing that needs a version marker in the tree; until then it is on the person
    // doing the vendoring.
    //
    // TODO: registry dependencies are still ignored entirely.
    private struct AnySPMDependency: Decodable {
        let dependencies: [SPMPackageDependency]

        enum CodingKeys: String, CodingKey { case fileSystem, sourceControl }

        init(from decoder: Decoder) throws {
            let c             = try decoder.container(keyedBy: CodingKeys.self)
            let fileSystem    = (try? c.decode([SPMFileSystemDependency].self,    forKey: .fileSystem))    ?? []
            let sourceControl = (try? c.decode([SPMSourceControlDependency].self, forKey: .sourceControl)) ?? []

            dependencies =
                fileSystem.map { SPMPackageDependency(path: $0.path, repositoryURL: nil) } +
                sourceControl.compactMap { control in
                    control.vendoredSiblingPath.map {
                        SPMPackageDependency(path: $0, repositoryURL: control.repositoryURL)
                    }
                }
        }
    }

    /// A package dependency reduced to a local path. `repositoryURL` is nil for a
    /// fileSystem dependency, whose path the manifest stated outright, and set for a
    /// sourceControl one, whose path is a convention this build system applied — which is
    /// exactly the difference a user needs told when nothing is at that path.
    private struct SPMPackageDependency {
        let path: String
        let repositoryURL: String?
    }

    private struct SPMFileSystemDependency: Decodable {
        let identity: String
        let path: String
    }

    private struct SPMSourceControlDependency: Decodable {
        /// nil when the location is not a remote URL, or the URL names nothing usable.
        let repositoryName: String?
        /// Kept verbatim so a stalled build can name what it is waiting for.
        let repositoryURL: String?

        private struct Location: Decodable {
            struct Remote: Decodable { let urlString: String }
            let remote: [Remote]?
        }

        enum CodingKeys: String, CodingKey { case location }

        init(from decoder: Decoder) throws {
            let c    = try decoder.container(keyedBy: CodingKeys.self)
            let url  = (try? c.decode(Location.self, forKey: .location))?.remote?.first?.urlString
            repositoryURL  = url
            repositoryName = url.flatMap { Self.directoryName(forRepositoryURL: $0) }
        }

        /// A vendored dependency sits beside the package that named it.
        var vendoredSiblingPath: String? {
            repositoryName.map { "../\($0)" }
        }

        /// "https://github.com/groue/GRDB.swift.git" -> "GRDB.swift".
        ///
        /// Derived from the URL rather than from SPM's `identity`, which is lowercased
        /// ("grdb.swift") and so cannot name a directory on a case-sensitive filesystem.
        /// Splits on ":" as well as "/" so scp-style remotes (git@host:owner/repo.git)
        /// resolve the same way.
        static func directoryName(forRepositoryURL urlString: String) -> String? {
            var name = urlString
            while name.hasSuffix("/") { name.removeLast() }
            if let lastSeparator = name.lastIndex(where: { $0 == "/" || $0 == ":" }) {
                name = String(name[name.index(after: lastSeparator)...])
            }
            if name.hasSuffix(".git") { name.removeLast(4) }
            return name.isEmpty ? nil : name
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
        /// Non-decoded. Set only on synthetic targets created for external packages.
        var overridePackageFolder: String?

        enum CodingKeys: String, CodingKey {
            case name, type, path, dependencies, sources, exclude
        }

        init(from decoder: Decoder) throws {
            let c        = try decoder.container(keyedBy: CodingKeys.self)
            name         = try c.decode(String.self, forKey: .name)
            type         = try? c.decode(String.self, forKey: .type)
            path         = try? c.decode(String.self, forKey: .path)
            dependencies = (try? c.decode([SPMTargetDependency].self, forKey: .dependencies)) ?? []
            sources      = (try? c.decode([String].self, forKey: .sources)) ?? []
            exclude      = (try? c.decode([String].self, forKey: .exclude)) ?? []
            overridePackageFolder = nil
        }

        // SPM default: Sources/<TargetName> relative to the package root.
        var sourcesRelativePath: String { path ?? "Sources/\(name)" }

        // systemLibrary targets (type == "system-target") wrap C system libraries
        // via a module.modulemap.  They have no Swift sources and cannot be compiled
        // with SwiftCompilerTool.
        var isSystemLibrary: Bool { type == "system-target" || type == "system" }
    }

    // Handles the two dependency shapes emitted by different Swift versions:
    //   array form  – {"byName": ["Name", null]}
    //   object form – {"byName": {"name": "Name", "condition": null}}
    // Both local target names and external product names are extracted; the
    // distinction is resolved at formula-generation time via allTargetsByName.
    private struct SPMTargetDependency: Decodable {
        let targetName: String?

        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String)          { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int)       { nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            var found: String? = nil

            for key in ["byName", "target", "product"] {
                guard found == nil, c.contains(AnyKey(key)) else { continue }
                if let arr = try? c.decode([String?].self, forKey: AnyKey(key)) {
                    found = arr.compactMap { $0 }.first
                } else if let sub = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(key)),
                          let n   = try? sub.decode(String.self, forKey: AnyKey("name")) {
                    found = n
                }
            }
            targetName = found
        }
    }

    private struct SPMProduct: Decodable {
        let name: String
        let targets: [String]
        let productType: ProductType

        enum ProductType { case executable, library, other }

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
            if      tc.contains(AnyKey("executable")) { productType = .executable }
            else if tc.contains(AnyKey("library"))    { productType = .library }
            else                                       { productType = .other }
        }
    }

    // MARK: - Formula generation

    private func generateFormula(rootManifest: SPMManifest,
                                 externalManifests: [String: SPMManifest],
                                 rootPackageFolder: String) -> String {
        // Build combined target name → SPMTarget map.
        // External targets carry overridePackageFolder so buildFuncDef uses the
        // correct source root.  Root targets take precedence on any name conflict.
        var allTargetsByName: [String: SPMTarget] = [:]
        for (extFolder, extManifest) in externalManifests {
            for var target in extManifest.targets {
                target.overridePackageFolder = extFolder
                allTargetsByName[target.name] = target
            }
        }
        for target in rootManifest.targets {
            allTargetsByName[target.name] = target  // root wins
        }

        // Resolves a dependency name to all SPMTargets it represents.
        // A direct target name returns one element; a product name returns every
        // target listed in that product so multi-target products are fully covered.
        func allTargetsNamed(_ name: String) -> [SPMTarget] {
            if let t = allTargetsByName[name] { return [t] }
            for (extFolder, extManifest) in externalManifests {
                guard let product = extManifest.products.first(where: { $0.name == name }) else { continue }
                return product.targets.compactMap { targetName in
                    var t = extManifest.targets.first(where: { $0.name == targetName })
                    t?.overridePackageFolder = extFolder
                    return t
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
            for productTargetName in product.targets {
                for rootTarget in allTargetsNamed(productTargetName) {
                    for target in collectTransitiveTargets(root: rootTarget, lookupAll: allTargetsNamed) {
                        guard collected.insert(target.name).inserted else { continue }
                        allTargets.append(target)
                    }
                }
            }

            // A product that reduces to no compilable targets — GRDB's `GRDBSQLite`
            // library vends nothing but a .systemLibrary — has no object files to link.
            // Emitting a SwiftLinkerTool for it anyway leaves its required `input` port
            // unwired, which fails the entire ProjectBuilder rather than just that product.
            guard !allTargets.isEmpty else { continue }

            // Emit one func definition per unique target (shared across products).
            for target in allTargets {
                let fn = compilerFuncName(for: target.name)
                guard !emittedFuncs.contains(fn) else { continue }
                blocks.append(buildFuncDef(target: target,
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
            let isLibrary    = (product.productType == .library)
            let outputName   = isLibrary ? "lib\(product.name).dylib" : product.name
            let linkerConfig = configurationExpression(
                namespace: SwiftLinkerToolConfiguration.settingNamespace,
                packageFolder: rootPackageFolder,
                literals: ["dynamicLibrary": isLibrary ? "true" : "false",
                           "outputName":     outputName])

            // One object-file wire per compiled target (all transitive deps included).
            let objectWires = allTargets.map { t in
                "        '\(t.name).o': \(compilerFuncName(for: t.name))().object"
            }

            // Every system library the product reaches, so a vendored static archive
            // dropped in one of those folders is linked in.  The linker needs the same
            // folders the compiler already gets for their module maps — see
            // SwiftLinkerTool.libraryFolders.
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

            let block =
                "product '\(outputName)' =\n" +
                "    SwiftLinkerTool(\n" +
                linkerArgs + "\n" +
                "    ).output"
            blocks.append(block)
        }

        return blocks.joined(separator: "\n\n")
    }

    // Every product the package should actually produce.
    //
    // `swift build` builds an executable target whether or not a product lists it, and
    // manifests rely on that: this repository's own root manifest declares no products at
    // all and still yields the `build_system` binary.  Emitting only declared products
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
            guard !visited.contains(target.name) else { return }
            // System-library targets (module.modulemap wrappers) have no Swift
            // sources.  Skip them here; buildFuncDef handles them separately via
            // inputModuleMapFolders when they appear as a dependency.
            guard !target.isSystemLibrary else { return }
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
            guard visited.insert(target.name).inserted else { return }
            for dep in target.dependencies {
                guard let depName = dep.targetName else { continue }
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

    // "MyTarget-A" → "compilerMyTarget_A"  (must be a valid formula identifier)
    private func compilerFuncName(for targetName: String) -> String {
        let sanitized = String(targetName.map { $0.isLetter || $0.isNumber ? $0 : Character("_") })
        return "compiler\(sanitized)"
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
        var derived = ["moduleName": target.name]
        if target.type == "executable" {
            derived["parseAsLibrary"] = "false"
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

        let configExpr = configurationExpression(namespace: SwiftCompilerToolConfiguration.settingNamespace,
                                                  packageFolder: pkgRoot,
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
            let fn = compilerFuncName(for: depTarget.name)
            moduleWires.append("            '\(depTarget.name)': \(fn)().swiftmodule")
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

        var args =
            "    configuration: ['config': \(configExpr)],\n" +
            "    inputFolder: ['folder0': \(folderExpr)]"
        if !moduleWires.isEmpty {
            args += ",\n    inputModules: [\n" + moduleWires.joined(separator: ",\n") + "\n    ]"
        }
        if !moduleMapFolderWires.isEmpty {
            args += ",\n    inputModuleMapFolders: [\n" + moduleMapFolderWires.joined(separator: ",\n") + "\n    ]"
        }
        return "func \(compilerFuncName(for: target.name))() =\n    SwiftCompilerTool(\n\(args)\n    )"
    }

    // Resolves a relative path (which may contain "..") against a base path.
    // Both paths are virtual input-filesystem paths, not real filesystem paths.
    private func resolveRelativePath(_ relative: String, from base: String) -> String {
        var components = base.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for part in relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            switch part {
            case ".":  break
            case "..": if !components.isEmpty { components.removeLast() }
            default:   components.append(part)
            }
        }
        return components.joined(separator: "/")
    }
}
