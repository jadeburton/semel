// SwiftFormulaConverter.swift
// BuildSystemCore
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

struct SwiftFormulaConverter: NodeFunction {
    static let kind: UInt = 24

    static let packageFolder        = "packageFolder"
    static let packageJSON          = "packageJSON"
    static let formulaOutput        = "formula"
    static let infoLog              = "infoLog"
    static let externalPackageJSONs = "externalPackageJSONs"

    var embeddedNode: Node

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    static let descriptor = NodeFunctionDescriptor(
        inputPorts: [
            .required(packageFolder),
            .required(packageJSON),
            .dynamic(externalPackageJSONs),
        ],
        outputPorts: [formulaOutput, infoLog]
    )

    // MARK: - Processing

    func process(input: ProcessInput) throws -> ProcessOutput {

        // ── packageFolder ─────────────────────────────────────────────────────
        let manifestJSON = try input.inputValues[Self.packageFolder]!.values.first!.expectValue().resolveAsString()

        guard let folderManifest = try? PolyFactory.decode(encodedJSON: manifestJSON) as? FolderManifest else {
            return pendingOutput(reason: "SwiftFormulaConverter: could not decode FolderManifest",
                                 externalExpectations: [:])
        }

        let rootPackageFolder = folderManifest.baseFolderPath

        // ── root packageJSON ──────────────────────────────────────────────────
        let jsonEntry = try input.inputValues[Self.packageJSON]!.values.first!.expectValue()

        let rootManifest: SPMManifest

        do {
            rootManifest = try SPMManifest.decode(try jsonEntry.resolveAsString())
        } catch {
            return pendingOutput(reason: "SwiftFormulaConverter: \(error)", externalExpectations: [:])
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
        var bfsIndex = 0

        while bfsIndex < bfsQueue.count {
            let (manifestPath, manifest) = bfsQueue[bfsIndex]; bfsIndex += 1
            for dep in manifest.packageDependencies {
                let extPath = resolveRelativePath(dep.path, from: manifestPath)
                // Skip dependencies whose resolved path falls outside the virtual
                // inputFileSystem — they are system-level or truly external packages
                // that cannot be read through the build graph.
                guard extPath.hasPrefix(Folder.inputFileSystemName + "/") else { continue }
                guard !visitedPaths.contains(extPath) else { continue }
                visitedPaths.insert(extPath)
                expectations[extPath] = packageReaderExpectation(for: extPath)
                if let extManifest = availableManifests[extPath] {
                    bfsQueue.append((extPath, extManifest))
                }
            }
        }

        // ── wait until every expected manifest has been received ──────────────
        let missing = expectations.keys.filter { availableManifests[$0] == nil }
        guard missing.isEmpty else {
            return pendingOutput(
                reason: "SwiftFormulaConverter: awaiting external packages: \(missing.sorted().joined(separator: ", "))",
                externalExpectations: expectations)
        }

        // ── all manifests present — generate formula ──────────────────────────
        let formula = generateFormula(rootManifest: rootManifest,
                                      externalManifests: availableManifests,
                                      rootPackageFolder: rootPackageFolder)
        return .init(
            outputValues: [Self.formulaOutput: .value(formula.intern()),
                           Self.infoLog:       .value("".intern())],
            inputWireExpectations: [Self.externalPackageJSONs: expectations])
    }

    // Returns a noValue output that still carries the current expectations,
    // so applyExpectationConfiguration keeps (or creates) the needed wires.
    private func pendingOutput(reason: String, externalExpectations: [String: String]) -> ProcessOutput {
        .init(outputValues: [Self.formulaOutput: .noValue(reason: .error(message: reason)),
                             Self.infoLog:       .value("".intern())],
              inputWireExpectations: [Self.externalPackageJSONs: externalExpectations])
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

    // MARK: - SPM JSON model

    private struct SPMManifest: Decodable {
        let name: String
        let targets: [SPMTarget]
        let products: [SPMProduct]
        /// fileSystem-based package dependencies (local paths only).
        let packageDependencies: [SPMFileSystemDependency]

        enum CodingKeys: String, CodingKey {
            case name, targets, products, dependencies
        }

        init(from decoder: Decoder) throws {
            let c        = try decoder.container(keyedBy: CodingKeys.self)
            name         = try c.decode(String.self,      forKey: .name)
            targets      = try c.decode([SPMTarget].self,  forKey: .targets)
            products     = try c.decode([SPMProduct].self, forKey: .products)
            let rawDeps  = (try? c.decode([AnySPMDependency].self, forKey: .dependencies)) ?? []
            packageDependencies = rawDeps.compactMap { $0.fileSystem }.flatMap { $0 }
        }

        static func decode(_ json: String) throws -> SPMManifest {
            try JSONDecoder().decode(SPMManifest.self, from: Data(json.utf8))
        }
    }

    // Decodes one element of the top-level "dependencies" array, extracting only
    // fileSystem (local-path) entries and ignoring sourceControl / registry.
    private struct AnySPMDependency: Decodable {
        let fileSystem: [SPMFileSystemDependency]?

        enum CodingKeys: String, CodingKey { case fileSystem }

        init(from decoder: Decoder) throws {
            let c      = try decoder.container(keyedBy: CodingKeys.self)
            fileSystem = try? c.decodeIfPresent([SPMFileSystemDependency].self, forKey: .fileSystem)
        }
    }

    private struct SPMFileSystemDependency: Decodable {
        let identity: String
        let path: String
    }

    private struct SPMTarget: Decodable {
        let name: String
        let type: String?
        let path: String?
        let dependencies: [SPMTargetDependency]
        /// Non-decoded. Set only on synthetic targets created for external packages.
        var overridePackageFolder: String?

        enum CodingKeys: String, CodingKey {
            case name, type, path, dependencies
        }

        init(from decoder: Decoder) throws {
            let c        = try decoder.container(keyedBy: CodingKeys.self)
            name         = try c.decode(String.self, forKey: .name)
            type         = try? c.decode(String.self, forKey: .type)
            path         = try? c.decode(String.self, forKey: .path)
            dependencies = (try? c.decode([SPMTargetDependency].self, forKey: .dependencies)) ?? []
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

        for product in rootManifest.products {
            guard product.productType != .other,
                  let primaryTargetName = product.targets.first,
                  let primaryTarget = allTargetsByName[primaryTargetName] else { continue }

            // All transitively reachable targets in dependency-first order so
            // each func is defined before any func that references it.
            let allTargets = collectTransitiveTargets(root: primaryTarget, lookupAll: allTargetsNamed)

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
            let isLibrary    = (product.productType == .library)
            let outputName   = isLibrary ? "lib\(product.name).dylib" : product.name
            let linkerConfig = "Configuration(dynamicLibrary: '\(isLibrary ? "true" : "false")', outputName: '\(outputName)').output"

            // One object-file wire per compiled target (all transitive deps included).
            let objectWires = allTargets.map { t in
                "        '\(t.name).o': \(compilerFuncName(for: t.name))().object"
            }

            let block =
                "product '\(product.name)' =\n" +
                "    SwiftLinkerTool(\n" +
                "        configuration: ['config': \(linkerConfig)],\n" +
                "        input: [\n" +
                objectWires.joined(separator: ",\n") + "\n" +
                "        ]\n" +
                "    ).output"
            blocks.append(block)
        }

        return blocks.joined(separator: "\n\n")
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
        let configExpr  = target.type == "executable"
            ? "Configuration(moduleName: '\(target.name)', parseAsLibrary: 'false').output"
            : "Configuration(moduleName: '\(target.name)').output"
        let folderExpr  = "Folder(path: '\(sourcesPath)').manifest"

        var moduleWires: [String] = []
        var moduleMapFolderWires: [String] = []
        for dep in target.dependencies {
            guard let depName = dep.targetName else { continue }
            for depTarget in lookupAll(depName) {
                if depTarget.isSystemLibrary {
                    // Place the module.modulemap directory into the sandbox so
                    // swiftc can resolve the system module (e.g. GRDBSQLite).
                    let depPkgRoot    = depTarget.overridePackageFolder ?? packageFolder
                    let mapFolderPath = "\(depPkgRoot)/\(depTarget.sourcesRelativePath)"
                    moduleMapFolderWires.append("            '\(depTarget.name)': Folder(path: '\(mapFolderPath)').manifest")
                } else {
                    let fn = compilerFuncName(for: depTarget.name)
                    moduleWires.append("            '\(depTarget.name)': \(fn)().swiftmodule")
                }
            }
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
