//
//  SwiftFormulaConverterTests.swift
//  semel_tests
//
//  The converter turns a `swift package dump-package` manifest into the .fmla text
//  ProjectBuilder consumes, so the interesting assertions are all about which blocks
//  come out of it for a given manifest shape.
//

@testable import SemelSwift
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class SwiftFormulaConverterTests: SemelSwiftTestCase {

    // MARK: - Helpers

    private func makeConverter() throws -> SwiftFormulaConverter {
        try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind))
    }

    /// The converter asks for every compilable target's folder as a tree before generating
    /// (B-54: the folder is what says whether a target is C or Swift; B-77, B-135: the
    /// folders below it say which resources it carries). The trees these tests do not care
    /// about are supplied here from the JSON itself, one `.swift` file per target;
    /// `folderContents` gives a folder's entries, and every folder's below it, for the
    /// tests that do.
    private func targetFolderTrees(packageFolder: String,
                                   json: String,
                                   externalManifests: [String: String],
                                   folderContents: [String: [FolderManifestEntry]]) throws -> [String: NodeValue] {
        var trees: [String: NodeValue] = [:]
        for (folder, text) in [(packageFolder, json)] + externalManifests.map { ($0.key, $0.value) } {
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            for target in (object?["targets"] as? [[String: Any]]) ?? [] {
                let name = target["name"] as? String ?? ""
                let type = target["type"] as? String ?? "regular"
                guard !["test", "system", "system-target", "plugin", "binary"].contains(type) else { continue }
                let relative = PackageClangTarget.normalized(target["path"] as? String ?? "Sources/\(name)")
                let path = PackageClangTarget.joined(folder, relative)
                var listings = folderContents
                listings[path] = folderContents[path] ?? [FolderManifestEntry(name: "\(name).swift", isFolder: false, isPinned: true)]
                trees[path] = .value(try FolderSubtreeManifest.folding(at: path, listings: listings).toJSON().intern())
            }
        }
        return trees
    }

    private func targetNames(in manifests: [String]) throws -> [String] {
        try manifests.flatMap { text -> [String] in
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            return ((object?["targets"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        }
    }

    private func convert(packageFolder: String = "input:/pkg",
                         json: String,
                         externalManifests: [String: String] = [:],
                         folderContents: [String: [FolderManifestEntry]] = [:],
                         locks: [String: String] = [:],
                         contentRoots: [String: DataObjectHash] = [:],
                         wholeContentRoots: [String: DataObjectHash] = [:],
                         linkerSettings: String? = nil,
                         supplyTargetFolders: Bool = true) throws -> ProcessOutput {
        let manifest = FolderManifest(baseFolderPath: packageFolder, entries: folderContents[packageFolder] ?? [])
        var externalValues = [String: NodeValue]()
        for (path, externalJSON) in externalManifests {
            externalValues[path] = .value(try externalJSON.intern())
        }
        var inputValues: [String: [String: NodeValue]] = [
            SwiftFormulaConverter.packageFolder:        ["folder": .value(try manifest.toJSON().intern())],
            SwiftFormulaConverter.packageJSON:          ["json":   .value(try json.intern())],
            SwiftFormulaConverter.externalPackageJSONs: externalValues,
            SwiftFormulaConverter.targetFolders:        supplyTargetFolders
                ? try targetFolderTrees(packageFolder: packageFolder, json: json,
                                        externalManifests: externalManifests, folderContents: folderContents)
                : [:],
            SwiftFormulaConverter.dependencyLocks:        [:],
            SwiftFormulaConverter.dependencyContentRoots: [:],
        ]
        // Every tree the converter asks for holding binary targets' artifacts (B-77) is
        // answered from `folderContents`, or as empty. Every vendored package's lock (B-06)
        // is answered from `locks` by its path, or as a file nobody pushed; the content root
        // of each package whose lock is there, from `contentRoots`. The linker's settings,
        // asked for when a linker setting is conditional on a platform (B-55), from
        // `linkerSettings`, and left unanswered without it.
        let converter = try makeConverter()
        for _ in 0..<8 {
            let output = try converter.process(input: ProcessInput(inputValues: inputValues))
            func asked(_ port: String) -> [String] {
                (output.inputWireSpecs[port] ?? [:]).keys.filter { inputValues[port]?[$0] == nil }.sorted()
            }
            let lockFiles     = asked(SwiftFormulaConverter.dependencyLocks)
            let lockedFolders = asked(SwiftFormulaConverter.dependencyContentRoots)
            let wholeRoots    = asked(SwiftFormulaConverter.dependencyWholeContentRoots)
            let linkerConfigs = linkerSettings == nil ? [] : asked(SwiftFormulaConverter.linkerConfiguration)
            let binaryFolders = asked(SwiftFormulaConverter.binaryArtifactFolders)
            let parents       = asked(SwiftFormulaConverter.targetFolderParents)
            let targetFolders = supplyTargetFolders ? asked(SwiftFormulaConverter.targetFolders) : []
            guard !lockFiles.isEmpty || !lockedFolders.isEmpty || !wholeRoots.isEmpty || !linkerConfigs.isEmpty
                    || !binaryFolders.isEmpty || !parents.isEmpty || !targetFolders.isEmpty else {
                return output
            }
            // A target folder found somewhere other than `Sources/<Target>`, from
            // `folderContents`.
            for folder in targetFolders {
                inputValues[SwiftFormulaConverter.targetFolders, default: [:]][folder] =
                    .value(try FolderSubtreeManifest.folding(at: folder, listings: folderContents).toJSON().intern())
            }
            // A folder a target that names none is looked for in (B-143): from
            // `folderContents`, or else as SwiftPM's first guess has it — a package folder
            // holding `Sources`, and `Sources` holding a folder for every target.
            for parent in parents {
                var entries = folderContents[parent]
                if entries == nil, parent.hasSuffix("/Sources") {
                    entries = try targetNames(in: [json] + Array(externalManifests.values)).map {
                        FolderManifestEntry(name: $0, isFolder: true, isPinned: true)
                    }
                }
                let listing = FolderManifest(baseFolderPath: parent,
                                             entries: entries ?? [FolderManifestEntry(name: "Sources", isFolder: true, isPinned: true)])
                inputValues[SwiftFormulaConverter.targetFolderParents, default: [:]][parent] =
                    .value(try listing.toJSON().intern())
            }
            for folder in wholeRoots {
                inputValues[SwiftFormulaConverter.dependencyWholeContentRoots, default: [:]][folder] =
                    .value(try XCTUnwrap(wholeContentRoots[folder] ?? contentRoots[folder],
                                         "the converter asked for the whole root of \(folder)"))
            }
            for folder in binaryFolders {
                inputValues[SwiftFormulaConverter.binaryArtifactFolders, default: [:]][folder] =
                    .value(try FolderSubtreeManifest.folding(at: folder, listings: folderContents).toJSON().intern())
            }
            for key in linkerConfigs {
                inputValues[SwiftFormulaConverter.linkerConfiguration, default: [:]][key] =
                    .value(try XCTUnwrap(linkerSettings).intern())
            }
            for lockFile in lockFiles {
                inputValues[SwiftFormulaConverter.dependencyLocks]?[lockFile] =
                    try locks[lockFile].map { .value(try $0.intern()) } ?? .noValue(reason: .initializing)
            }
            for folder in lockedFolders {
                inputValues[SwiftFormulaConverter.dependencyContentRoots]?[folder] =
                    .value(try XCTUnwrap(contentRoots[folder], "the converter asked for the content root of \(folder)"))
            }
        }
        XCTFail("the converter kept asking for trees, locks or content roots")
        return try converter.process(input: ProcessInput(inputValues: inputValues))
    }

    private func formula(packageFolder: String = "input:/pkg",
                         json: String,
                         externalManifests: [String: String] = [:],
                         folderContents: [String: [FolderManifestEntry]] = [:],
                         linkerSettings: String? = nil) throws -> String {
        let output = try convert(packageFolder: packageFolder, json: json,
                                 externalManifests: externalManifests, folderContents: folderContents,
                                 linkerSettings: linkerSettings)
        return try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput]).expectValue().resolveAsString()
    }

    /// The text of a single `func compilerX() = …` definition. Assertions about one
    /// target's wiring must be scoped to its own block, or another target's identical
    /// wiring will satisfy them.
    private func funcDefinition(_ funcName: String, in formula: String) throws -> String {
        try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix("func \(funcName)()") },
                      "no \(funcName) block in:\n\(formula)")
    }

    private func externalSpecs(_ output: ProcessOutput) throws -> [String: String] {
        try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.externalPackageJSONs]).rendered
    }

    /// DatabaseModels' real shape: GRDB arrives as a git URL, not a local path.
    private func sourceControlManifest(url: String = "https://github.com/groue/GRDB.swift.git") -> String {
        """
        {
          "name": "DatabaseModels",
          "dependencies": [
            {"sourceControl": [{"identity": "grdb.swift",
                                "location": {"remote": [{"urlString": "\(url)"}]},
                                "requirement": {"range": [{"lowerBound": "7.11.1", "upperBound": "8.0.0"}]}}]}
          ],
          "products": [
            {"name": "DatabaseModels", "targets": ["DatabaseModels"], "type": {"library": ["automatic"]}}
          ],
          "targets": [
            {"name": "DatabaseModels", "type": "regular", "path": "Sources/DatabaseModels",
             "dependencies": [{"product": ["GRDB", "GRDB.swift", null, null]}]}
          ]
        }
        """
    }

    /// The shape GRDB actually dumps: a `.systemLibrary` target that is both vended as
    /// its own product and depended on by the real target.
    private let grdbShapedManifest = """
        {
          "name": "GRDB",
          "dependencies": [],
          "products": [
            {"name": "GRDBSQLite", "targets": ["GRDBSQLite"], "type": {"library": ["automatic"]}},
            {"name": "GRDB",       "targets": ["GRDB"],       "type": {"library": ["automatic"]}}
          ],
          "targets": [
            {"name": "GRDBSQLite", "type": "system",  "path": "Sources/GRDBSQLite", "dependencies": []},
            {"name": "GRDB",       "type": "regular", "path": "GRDB",
             "dependencies": [{"target": ["GRDBSQLite", null]}]}
          ]
        }
        """

    // MARK: - Products that vend no compilable targets

    /// A product whose targets are all system libraries has nothing to link. Emitting a
    /// SwiftLinker for it leaves the required `input` port with no wires, which fails
    /// the whole ProjectBuilder with requiredPortUnwired.
    func test_skipsProductsThatVendOnlySystemLibraries() throws {
        let result = try formula(json: grdbShapedManifest)

        let productLabels = result.components(separatedBy: "\n\n")
            .filter { $0.hasPrefix("product ") }
            .compactMap { $0.components(separatedBy: "'").dropFirst().first }

        XCTAssertFalse(productLabels.contains { $0.contains("GRDBSQLite") },
                       "GRDBSQLite vends only a system library, got: \(productLabels)")
        XCTAssertTrue(productLabels.contains("libGRDB.a"),
                      "the real product should still be emitted, got: \(productLabels)")
    }

    func test_emitsNoLinkerWithAnEmptyInputList() throws {
        let result = try formula(json: grdbShapedManifest)

        XCTAssertFalse(result.contains("input: [\n\n        ]"),
                       "a linker with no object wires would fail as requiredPortUnwired, got:\n\(result)")
    }

    // MARK: - System libraries at link time

    private func productBlock(_ label: String, in formula: String) throws -> String {
        try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix("product '\(label)'") },
                      "no product '\(label)' block in:\n\(formula)")
    }

    /// The compile side already places a system library's folder in the sandbox for its
    /// module map. The link side needs the same folder, because that is where a vendored
    /// static archive is dropped — without it the modulemap's `link "sqlite3"` resolves
    /// against the SDK and the product depends on the system copy instead.
    func test_wiresASystemLibraryFolderToTheLinker() throws {
        let block = try productBlock("libGRDB.a", in: try formula(json: grdbShapedManifest))

        XCTAssertTrue(block.contains("libraryFolders: [\n            'GRDBSQLite': Folder(path: 'input:/pkg/Sources/GRDBSQLite').manifest\n        ]"),
                      "got:\n\(block)")
    }

    /// A product with no system library anywhere in its closure must emit exactly what it
    /// did before, or every existing project relinks for nothing.
    func test_omitsTheLibraryFoldersPortWhenNoSystemLibraryIsReached() throws {
        let result = try formula(json: """
            {
              "name": "plain",
              "dependencies": [],
              "products": [{"name": "plain", "targets": ["Plain"], "type": {"executable": null}}],
              "targets": [{"name": "Plain", "type": "executable", "path": "Plain", "dependencies": []}]
            }
            """)

        XCTAssertFalse(result.contains("libraryFolders"), "got:\n\(result)")
    }

    /// Same reach as the module map: the executable is three packages away and names
    /// GRDBSQLite nowhere, but its archive still has to be on the link line.
    func test_reachesASystemLibraryThroughThreePackagesAtLinkTime() throws {
        let block = try productBlock("semel", in: try rootFormula())

        XCTAssertTrue(block.contains("'GRDBSQLite': Folder(path: 'input:/repo/Dependencies/GRDB.swift/Sources/GRDBSQLite').manifest"),
                      "got:\n\(block)")
    }

    // MARK: - Product file names

    /// The product's formula label becomes its file name in the output file system, so it
    /// has to be the name the linker actually writes. A library is linked as
    /// lib<name>.<ext> but was published as the bare product name, so a library appeared
    /// with neither the lib prefix nor the extension. GRDB's products are `.automatic`,
    /// which links as an archive.
    func test_publishesALibraryUnderItsLinkedFileName() throws {
        let result = try formula(json: grdbShapedManifest)

        XCTAssertTrue(result.contains("product 'libGRDB.a' ="), "got:\n\(result)")
        XCTAssertTrue(result.contains("outputName: 'libGRDB.a'"), "got:\n\(result)")
    }

    // MARK: - Library type (B-09)

    private func libraryManifest(type: String) -> String {
        """
        {
          "name": "L",
          "dependencies": [],
          "products": [{"name": "L", "targets": ["L"], "type": {"library": ["\(type)"]}}],
          "targets": [{"name": "L", "type": "regular", "path": "Sources/L", "dependencies": []}]
        }
        """
    }

    private func linkerConfiguration(in formula: String) throws -> String {
        let block = try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix("product ") },
                                  "no product block in:\n\(formula)")
        return try XCTUnwrap(block.components(separatedBy: "\n").first { $0.contains("configuration: [") },
                             "no linker configuration in:\n\(block)")
    }

    /// `.library(type: .dynamic)` is the one case SPM links as a dylib.
    func test_linksADynamicLibraryProductAsADylib() throws {
        let result = try formula(json: libraryManifest(type: "dynamic"))

        XCTAssertTrue(result.contains("product 'libL.dylib' ="), "got:\n\(result)")
        XCTAssertTrue(try linkerConfiguration(in: result).contains("linkage: 'dynamicLibrary', outputName: 'libL.dylib'"),
                      "got:\n\(result)")
    }

    func test_linksAStaticLibraryProductAsAnArchive() throws {
        let result = try formula(json: libraryManifest(type: "static"))

        XCTAssertTrue(result.contains("product 'libL.a' ="), "got:\n\(result)")
        XCTAssertTrue(try linkerConfiguration(in: result).contains("linkage: 'staticArchive', outputName: 'libL.a'"),
                      "got:\n\(result)")
    }

    /// `.automatic` used to be built dynamic by assumption. SPM never links an automatic
    /// library on its own (`swift build --product L` produces only object files) and links
    /// it statically into whatever executable depends on it, so an archive is the artifact
    /// closest to what SPM would do.
    func test_linksAnAutomaticLibraryProductAsAnArchive() throws {
        let result = try formula(json: libraryManifest(type: "automatic"))

        XCTAssertTrue(result.contains("product 'libL.a' ="), "got:\n\(result)")
        XCTAssertTrue(try linkerConfiguration(in: result).contains("linkage: 'staticArchive', outputName: 'libL.a'"),
                      "got:\n\(result)")
    }

    func test_publishesAnExecutableUnderItsPlainName() throws {
        let result = try formula(json: """
            {
              "name": "tool",
              "dependencies": [],
              "products": [{"name": "tool", "targets": ["tool"], "type": {"executable": null}}],
              "targets": [{"name": "tool", "type": "executable", "path": "tool", "dependencies": []}]
            }
            """)

        XCTAssertTrue(result.contains("product 'tool' ="), "got:\n\(result)")
        XCTAssertFalse(result.contains("libtool"), "an executable takes no lib prefix, got:\n\(result)")
    }

    /// The label and the linker's outputName must not drift apart again — they are the
    /// same file, described in two places.
    func test_theProductLabelMatchesTheLinkedFileName() throws {
        let result = try formula(json: grdbShapedManifest)

        for block in result.components(separatedBy: "\n\n") where block.hasPrefix("product ") {
            let label = try XCTUnwrap(block.components(separatedBy: "'").dropFirst().first)
            XCTAssertTrue(block.contains("outputName: '\(label)'"),
                          "product '\(label)' is published under a name the linker does not write:\n\(block)")
        }
    }

    // MARK: - Multi-target products

    /// Only the product's first target used to seed the walk, so every later target was
    /// dropped — and a product whose first target is a system library collapsed to nothing.
    func test_linksEveryTargetOfAMultiTargetProduct() throws {
        let result = try formula(json: """
            {
              "name": "Multi",
              "dependencies": [],
              "products": [
                {"name": "Multi", "targets": ["SysLib", "Alpha", "Beta"], "type": {"library": ["automatic"]}}
              ],
              "targets": [
                {"name": "SysLib", "type": "system",  "path": "Sources/SysLib", "dependencies": []},
                {"name": "Alpha",  "type": "regular", "dependencies": []},
                {"name": "Beta",   "type": "regular", "dependencies": []}
              ]
            }
            """)

        XCTAssertTrue(result.contains("'Alpha.o': compilerAlpha().object"), "missing Alpha, got:\n\(result)")
        XCTAssertTrue(result.contains("'Beta.o': compilerBeta().object"),   "missing Beta, got:\n\(result)")
        XCTAssertFalse(result.contains("SysLib.o"), "a system library has no object file, got:\n\(result)")
    }

    /// Beside each product, two funcs another formula can call by the product's name:
    /// every module behind it and every object it links, as trees. An app's formula
    /// imports and links a package product through them without knowing its targets.
    func test_emitsModuleAndObjectTreesForEachProduct() throws {
        let result = try formula(json: """
            {
              "name": "Multi",
              "dependencies": [],
              "products": [
                {"name": "Multi-Kit", "targets": ["Alpha"], "type": {"library": ["automatic"]}}
              ],
              "targets": [
                {"name": "Alpha", "type": "regular", "dependencies": [{"byName": ["Beta", null]}]},
                {"name": "Beta",  "type": "regular", "dependencies": []}
              ]
            }
            """)

        XCTAssertTrue(result.contains("func modules_Multi_Kit() =\n    TreeMerger(input: [\n        'swift': TreeBuilder(input: ["), "got:\n\(result)")
        XCTAssertTrue(result.contains("'Alpha.swiftmodule': compilerAlpha().swiftmodule"), "got:\n\(result)")
        XCTAssertTrue(result.contains("'Beta.swiftmodule': compilerBeta().swiftmodule"), "got:\n\(result)")
        XCTAssertTrue(result.contains("func objects_Multi_Kit() =\n    TreeBuilder(input: ["), "got:\n\(result)")
        XCTAssertTrue(result.contains("'Beta.o': compilerBeta().object"), "got:\n\(result)")
        XCTAssertEqual(FormulaIdentifier.modulesFunc(forProduct: "Multi-Kit"), "modules_Multi_Kit")
    }

    // MARK: - System-library dependencies

    /// A system library reached as a dependency is not compiled; its directory is wired
    /// in so swiftc can find the module.modulemap. The path comes from the target's
    /// `path`, resolved against the package root.
    func test_wiresASystemLibraryDependencyAsAModuleMapFolder() throws {
        let result = try formula(json: grdbShapedManifest)

        XCTAssertTrue(result.contains("inputModuleMapFolders: [\n            'GRDBSQLite': Folder(path: 'input:/pkg/Sources/GRDBSQLite').manifest\n    ]"),
                      "got:\n\(result)")
    }

    /// A `.systemLibrary` declared without an explicit `path:` — the upstream GRDB shape —
    /// dumps `path: null`, and must fall back to Sources/<name> like any other target.
    /// Pointing `path:` at the dylib instead put a Folder node on a Mach-O file and the
    /// module.modulemap never reached the sandbox.
    func test_defaultsASystemLibraryPathToItsSourcesDirectory() throws {
        let result = try formula(json: """
            {
              "name": "GRDB",
              "dependencies": [],
              "products": [
                {"name": "GRDB", "targets": ["GRDB"], "type": {"library": ["automatic"]}}
              ],
              "targets": [
                {"name": "GRDBSQLite", "type": "system", "path": null, "dependencies": []},
                {"name": "GRDB",       "type": "regular", "path": "GRDB",
                 "dependencies": [{"target": ["GRDBSQLite", null]}]}
              ]
            }
            """)

        XCTAssertTrue(result.contains("'GRDBSQLite': Folder(path: 'input:/pkg/Sources/GRDBSQLite').manifest"),
                      "got:\n\(result)")
    }

    func test_doesNotEmitACompilerFuncForASystemLibrary() throws {
        let result = try formula(json: grdbShapedManifest)

        XCTAssertFalse(result.contains("func compilerGRDBSQLite()"), "got:\n\(result)")
    }

    /// A system library has to reach every target that imports it *transitively*.
    /// DatabaseModels names only GRDB, but GRDB.swiftmodule records the Clang module it
    /// was built against, so loading it without GRDBSQLite's module.modulemap on the
    /// import path fails with "missing required module 'GRDBSQLite'".
    func test_propagatesASystemLibraryModuleMapToTargetsThatImportItIndirectly() throws {
        let result = try formula(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest(),
                                 externalManifests: ["input:/repo/DatabaseModels/Dependencies/GRDB.swift": grdbShapedManifest])

        let block = try funcDefinition("compilerDatabaseModels", in: result)
        XCTAssertTrue(block.contains("'GRDBSQLite': Folder(path: 'input:/repo/DatabaseModels/Dependencies/GRDB.swift/Sources/GRDBSQLite').manifest"),
                      "got:\n\(block)")
    }

    /// The indirect import still wires the module itself, not a compiler func for the
    /// system library — that would try to compile a directory of headers.
    func test_anIndirectlyImportedSystemLibraryIsNotWiredAsASwiftModule() throws {
        let result = try formula(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest(),
                                 externalManifests: ["input:/repo/DatabaseModels/Dependencies/GRDB.swift": grdbShapedManifest])

        let block = try funcDefinition("compilerDatabaseModels", in: result)
        XCTAssertTrue(block.contains("'GRDB': compilerGRDB().swiftmodule"), "got:\n\(block)")
        XCTAssertFalse(block.contains("compilerGRDBSQLite"), "got:\n\(block)")
    }

    // MARK: - Where the config selector reads from

    /// Configuration is a property of the build, not of whichever package happens to be
    /// compiled. A consuming project cannot write a config file inside a vendored dependency
    /// it does not own, so a target compiled from an external package's checkout must still
    /// select its settings from the *root* package's semel.config, not its own.
    func test_anExternalTargetSelectsFromTheRootPackagesConfigFileNotItsOwn() throws {
        let result = try formula(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest(),
                                 externalManifests: ["input:/repo/DatabaseModels/Dependencies/GRDB.swift": grdbShapedManifest])

        let block = try funcDefinition("compilerGRDB", in: result)
        XCTAssertTrue(block.contains("StaticFile(path: 'input:/repo/DatabaseModels/semel.config')"),
                      "an external target must read the consuming project's config file, got:\n\(block)")
        XCTAssertFalse(block.contains("input:/repo/DatabaseModels/Dependencies/GRDB.swift/semel.config"),
                       "not a config file inside the vendored dependency, got:\n\(block)")
    }

    /// The reader that parses a vendored dependency's manifest shells out to a toolchain, so
    /// it needs `swift.packageReader.toolDescriptor.*` like every other tool. Wired to an
    /// empty `SettingsLiteral()` it throws before a single target is compiled.
    func test_theExternalPackageReaderIsWiredToASelectorForItsOwnNamespace() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest())

        let spec = try XCTUnwrap(try externalSpecs(output)["input:/repo/DatabaseModels/Dependencies/GRDB.swift"])
        XCTAssertTrue(spec.contains("ConfigFilter(prefix: 'swift.packageReader'"),
                      "got:\n\(spec)")
        XCTAssertFalse(spec.contains("SettingsLiteral().output"),
                       "an empty SettingsLiteral leaves the reader with no toolDescriptor, got:\n\(spec)")
    }

    /// Same rule as the compiler: the reader is part of *this* build, so it selects from the
    /// root package's config file rather than one inside the checkout it is reading.
    func test_theExternalPackageReaderSelectsFromTheRootPackagesConfigFileNotItsOwn() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest())

        let spec = try XCTUnwrap(try externalSpecs(output)["input:/repo/DatabaseModels/Dependencies/GRDB.swift"])
        XCTAssertTrue(spec.contains("StaticFile(path: 'input:/repo/DatabaseModels/semel.config')"),
                      "got:\n\(spec)")
        XCTAssertFalse(spec.contains("input:/repo/DatabaseModels/Dependencies/GRDB.swift/semel.config"),
                       "not a config file inside the vendored dependency, got:\n\(spec)")
    }

    // MARK: - Explicit source lists

    /// The converter cannot enumerate files — it only wires folders — so a target's
    /// `sources:`/`exclude:` lists have to travel to SwiftCompiler as configuration
    /// and be applied there, during discovery.
    func test_carriesAnExplicitSourcesListIntoTheCompilerConfiguration() throws {
        let result = try formula(json: """
            {
              "name": "semel",
              "dependencies": [],
              "products": [],
              "targets": [
                {"name": "semel", "type": "executable", "path": "semel",
                 "sources": ["main.swift"], "dependencies": []}
              ]
            }
            """)

        XCTAssertTrue(result.contains("sourcePaths: 'main.swift'"), "got:\n\(result)")
    }

    func test_carriesAnExcludeListIntoTheCompilerConfiguration() throws {
        let result = try formula(json: """
            {
              "name": "lib",
              "dependencies": [],
              "products": [{"name": "lib", "targets": ["Helper"], "type": {"library": ["automatic"]}}],
              "targets": [
                {"name": "Helper", "type": "regular", "path": "Sources/Helper",
                 "exclude": ["Fixtures", "notes.md"], "dependencies": []}
              ]
            }
            """)

        XCTAssertTrue(result.contains("excludedPaths: 'Fixtures,notes.md'"), "got:\n\(result)")
    }

    /// A target with neither list must add neither key to the compiler's configuration,
    /// or every cached node in every existing project is invalidated for nothing.
    func test_omitsBothListsWhenTheTargetDeclaresNeither() throws {
        let result = try formula(json: """
            {
              "name": "lib",
              "dependencies": [],
              "products": [{"name": "lib", "targets": ["Helper"], "type": {"library": ["automatic"]}}],
              "targets": [{"name": "Helper", "type": "regular", "path": "Sources/Helper", "dependencies": []}]
            }
            """)

        XCTAssertTrue(result.contains(
            "ConfigMerger(base: ['settings': "
            + "ConfigFilter(prefix: 'swift.compiler', "
            + "input: ['config': ConfigMerger(base: ['machine': StaticFile(path: 'input:/pkg/semel.machine.config').output], "
            + "override: ['project': StaticFile(path: 'input:/pkg/semel.config').output]).output]).output], "
            + "override: ['literals': SettingsLiteral(defines: 'SWIFT_PACKAGE', moduleName: 'Helper', packageName: 'lib').output]).output"),
            "got:\n\(result)")
    }

    // MARK: - Implicit executable products

    /// This repository's own root manifest declares no products at all — `swift build`
    /// builds the executable target directly. Iterating only declared products emitted an
    /// empty formula and produced nothing, with no error to say why.
    func test_emitsAnExecutableTargetThatNoProductDeclares() throws {
        let result = try formula(json: """
            {
              "name": "semel",
              "dependencies": [],
              "products": [],
              "targets": [
                {"name": "semel", "type": "executable", "path": "semel", "dependencies": []}
              ]
            }
            """)

        XCTAssertTrue(result.contains("product 'semel' ="), "got:\n\(result)")
        XCTAssertTrue(result.contains("func compilersemel()"), "got:\n\(result)")
    }

    /// An implicit product is an executable, not a library — it must not be linked as
    /// libsemel.dylib.
    func test_linksAnImplicitExecutableProductAsAnExecutable() throws {
        let result = try formula(json: """
            {
              "name": "semel",
              "dependencies": [],
              "products": [],
              "targets": [
                {"name": "semel", "type": "executable", "path": "semel", "dependencies": []}
              ]
            }
            """)

        XCTAssertTrue(result.contains(
            "ConfigMerger(base: ['settings': "
            + "ConfigFilter(prefix: 'swift.linker', "
            + "input: ['config': ConfigMerger(base: ['machine': StaticFile(path: 'input:/pkg/semel.machine.config').output], "
            + "override: ['project': StaticFile(path: 'input:/pkg/semel.config').output]).output]).output], "
            + "override: ['literals': SettingsLiteral(linkage: 'executable', outputName: 'semel').output]).output"),
            "got:\n\(result)")
    }

    func test_doesNotDuplicateAnExecutableTargetAProductAlreadyDeclares() throws {
        let result = try formula(json: """
            {
              "name": "tool",
              "dependencies": [],
              "products": [{"name": "tool", "targets": ["tool"], "type": {"executable": null}}],
              "targets": [
                {"name": "tool", "type": "executable", "path": "tool", "dependencies": []}
              ]
            }
            """)

        XCTAssertEqual(result.components(separatedBy: "product 'tool' =").count - 1, 1, "got:\n\(result)")
    }

    /// Library and test targets are not built on their own — only executables get the
    /// implicit treatment, matching what `swift build` does.
    func test_doesNotSynthesiseProductsForNonExecutableTargets() throws {
        let result = try formula(json: """
            {
              "name": "lib",
              "dependencies": [],
              "products": [],
              "targets": [
                {"name": "Helper",     "type": "regular", "path": "Sources/Helper", "dependencies": []},
                {"name": "HelperTests", "type": "test",   "path": "Tests",          "dependencies": []}
              ]
            }
            """)

        XCTAssertEqual(result.trimmingCharacters(in: .whitespacesAndNewlines), "", "got:\n\(result)")
    }

    // MARK: - Transitive Swift modules

    /// A binary .swiftmodule records the modules it was built against, so every one of
    /// them has to be on the import path of anything that loads it. Wiring only direct
    /// dependencies fails with "missing required modules: 'DatabaseModels', 'GRDB'" in a
    /// target that imports neither.
    func test_wiresTransitivelyReachedSwiftModules() throws {
        let result = try formula(json: """
            {
              "name": "app",
              "dependencies": [],
              "products": [{"name": "app", "targets": ["Top"], "type": {"executable": null}}],
              "targets": [
                {"name": "Top",    "type": "executable", "path": "Top",
                 "dependencies": [{"byName": ["Middle", null]}]},
                {"name": "Middle", "type": "regular", "path": "Middle",
                 "dependencies": [{"byName": ["Bottom", null]}]},
                {"name": "Bottom", "type": "regular", "path": "Bottom", "dependencies": []}
              ]
            }
            """)

        let block = try funcDefinition("compilerTop", in: result)
        XCTAssertTrue(block.contains("'Middle': compilerMiddle().swiftmodule"), "got:\n\(block)")
        XCTAssertTrue(block.contains("'Bottom': compilerBottom().swiftmodule"), "got:\n\(block)")
    }

    func test_aTargetIsNotWiredToItsOwnSwiftModule() throws {
        let result = try formula(json: """
            {
              "name": "app",
              "dependencies": [],
              "products": [{"name": "app", "targets": ["Top"], "type": {"executable": null}}],
              "targets": [
                {"name": "Top",    "type": "executable", "path": "Top",
                 "dependencies": [{"byName": ["Middle", null]}]},
                {"name": "Middle", "type": "regular", "path": "Middle", "dependencies": []}
              ]
            }
            """)

        let block = try funcDefinition("compilerTop", in: result)
        XCTAssertFalse(block.contains("'Top': compilerTop().swiftmodule"), "got:\n\(block)")
    }

    // MARK: - This repository's own root manifest

    /// Verbatim shape of `swift package dump-package` on this repo's root Package.swift:
    /// no products at all, an executable whose path contains two other targets, and a
    /// test target that must never be built.
    private let rootManifestShape = """
        {
          "name": "semel",
          "dependencies": [{"fileSystem": [{"identity": "buildsystemcore", "path": "SemelCore"}]}],
          "products": [],
          "targets": [
            {"name": "SemelCLI", "type": "regular", "path": "semel/CommandInterpreter",
             "dependencies": [{"product": ["SemelCore", "SemelCore", null, null]}]},
            {"name": "semel", "type": "executable", "path": "semel",
             "sources": ["main.swift"],
             "dependencies": [{"byName": ["SemelCLI", null]},
                              {"product": ["SemelCore", "SemelCore", null, null]}]},
            {"name": "SemelCLITests", "type": "test", "path": "semel/Tests",
             "dependencies": [{"byName": ["SemelCLI", null]}]}
          ]
        }
        """

    /// SemelCore as it really is: a path dependency of the root manifest that
    /// itself pulls in GRDB by git URL. Together with grdbShapedManifest this reproduces
    /// the whole production chain — root -> SemelCore -> GRDB -> GRDBSQLite.
    private let buildSystemCoreManifest = """
        {
          "name": "SemelCore",
          "dependencies": [
            {"sourceControl": [{"identity": "grdb.swift",
                                "location": {"remote": [{"urlString": "https://github.com/groue/GRDB.swift.git"}]}}]}
          ],
          "products": [
            {"name": "SemelCore", "targets": ["SemelCore"], "type": {"library": ["automatic"]}}
          ],
          "targets": [
            {"name": "SemelCore", "type": "regular", "path": "Sources/SemelCore",
             "dependencies": [{"product": ["GRDB", "GRDB.swift", null, null]}]}
          ]
        }
        """

    private func rootFormula() throws -> String {
        try formula(packageFolder: "input:/repo",
                    json: rootManifestShape,
                    externalManifests: ["input:/repo/SemelCore": buildSystemCoreManifest,
                                        "input:/repo/Dependencies/GRDB.swift":      grdbShapedManifest])
    }

    func test_buildsTheExecutableFromThisRepositorysOwnRootManifest() throws {
        let result = try rootFormula()

        XCTAssertTrue(result.contains("product 'semel' ="), "got:\n\(result)")
        XCTAssertTrue(result.contains("'semel.o': compilersemel().object"), "got:\n\(result)")
        XCTAssertTrue(result.contains("'SemelCLI.o': compilerSemelCLI().object"), "got:\n\(result)")
    }

    /// The executable's folder also holds SemelCLI's sources and the XCTest target,
    /// so the walk has to be held to `sources: ["main.swift"]`.
    func test_confinesTheExecutableTargetToItsDeclaredSources() throws {
        let result = try rootFormula()

        let block = try funcDefinition("compilersemel", in: result)
        XCTAssertTrue(block.contains("sourcePaths: 'main.swift'"), "got:\n\(block)")
        XCTAssertTrue(block.contains("Folder(path: 'input:/repo/semel').manifest"), "got:\n\(block)")
    }

    func test_neverBuildsTheTestTarget() throws {
        let result = try rootFormula()

        XCTAssertFalse(result.contains("SemelCLITests"), "got:\n\(result)")
    }

    /// The failure this whole chain produced: SemelCLI imports only SemelCore,
    /// but loading that module needs GRDB — and GRDB in turn needs GRDBSQLite's module map.
    /// Both have to reach a target three packages away that names neither.
    func test_reachesThroughThreePackagesToTheSystemLibrary() throws {
        let block = try funcDefinition("compilerSemelCLI", in: try rootFormula())

        XCTAssertTrue(block.contains("'GRDB': compilerGRDB().swiftmodule"), "got:\n\(block)")
        XCTAssertTrue(block.contains("'GRDBSQLite': Folder(path: 'input:/repo/Dependencies/GRDB.swift/Sources/GRDBSQLite').manifest"),
                      "got:\n\(block)")
    }

    // MARK: - Explaining a stall

    /// The document on a pending output, which is what the user is shown.
    private func pendingDocument(_ output: ProcessOutput) throws -> ErrorDocument {
        let value = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput])
        return try XCTUnwrap(value.errorDocument, "expected a document on the formula, got \(value)")
    }

    /// The one condition of a pending output.
    private func pendingCondition(_ output: ProcessOutput) throws -> ErrorCondition {
        guard case .engine(let condition) = try pendingDocument(output).diagnostic else {
            throw XCTSkip("expected one engine condition, got \(try pendingDocument(output))")
        }
        return condition
    }

    /// A vendored package that is not there stalls the whole conversion, and the document
    /// names the path it waits on and the repository that path stands for.
    func test_explainsWhichRepositoryAVendoredPathIsWaitingFor() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels", json: sourceControlManifest())

        XCTAssertEqual(try pendingDocument(output),
                       .engine(.packageNotPresent(path: "input:/repo/DatabaseModels/Dependencies/GRDB.swift",
                                                  origin: .repository(location: "https://github.com/groue/GRDB.swift.git")),
                               subject: .package(name: "GRDB.swift")))
    }

    /// Nothing is fetched: what puts a vendored package there is `prepare`, the remedy.
    func test_aVendoredPackageNotThereIsVendoredByPrepare() throws {
        let document = try pendingDocument(
            try convert(packageFolder: "input:/repo/DatabaseModels", json: sourceControlManifest()))

        XCTAssertEqual(document.remedy, .vendor)
    }

    /// A local path dependency has no repository behind it, so it must not claim one, and
    /// nothing vendors it.
    func test_describesAMissingLocalPathDependencyDifferently() throws {
        let document = try pendingDocument(try convert(packageFolder: "input:/repo/App", json: """
            {
              "name": "App",
              "dependencies": [{"fileSystem": [{"identity": "helper", "path": "../Helper"}]}],
              "products": [{"name": "App", "targets": ["App"], "type": {"executable": null}}],
              "targets": [{"name": "App", "type": "executable", "path": "App",
                           "dependencies": [{"product": ["Helper", "helper", null, null]}]}]
            }
            """))

        XCTAssertEqual(document.diagnostic, .engine(.packageNotPresent(path: "input:/repo/Helper", origin: nil)))
        XCTAssertNil(document.remedy)
    }

    /// The stall names what it waits for as a demand, not only as a sentence: the folder of
    /// each package whose manifest has not arrived, which a settle reports by path and a
    /// `build` pushes whole (B-110). A package that has arrived is not demanded.
    func test_aStallDemandsTheFolderOfEachPackageItWaitsFor() throws {
        let output = try convert(packageFolder: "input:/repo/SemelCore", json: """
            {
              "name": "SemelCore",
              "dependencies": [{"fileSystem": [{"identity": "databasemodels", "path": "../DatabaseModels"}]}],
              "products": [{"name": "SemelCore", "targets": ["SemelCore"], "type": {"library": ["automatic"]}}],
              "targets": [{"name": "SemelCore", "type": "regular", "path": "Sources/SemelCore",
                           "dependencies": [{"product": ["DatabaseModels", "databasemodels", null, null]}]}]
            }
            """, externalManifests: ["input:/repo/DatabaseModels": sourceControlManifest()])

        let awaited = try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.awaitedPackageFolders]).rendered
        XCTAssertEqual(awaited, ["input:/repo/SemelCore/Dependencies/GRDB.swift":
                                    "Folder(path: 'input:/repo/SemelCore/Dependencies/GRDB.swift').manifest"])
    }

    /// Once nothing is awaited the demand is withdrawn, or the folder would stay wired to a
    /// converter that no longer reads it.
    func test_aConversionThatStallsOnNothingDemandsNoPackageFolder() throws {
        let output = try convert(json: appOverCLib)

        XCTAssertEqual(output.inputWireSpecs[SwiftFormulaConverter.awaitedPackageFolders]?.isEmpty, true)
    }

    // MARK: - The lock beside a vendored package (B-06)

    private let vendoredGRDB = "input:/repo/DatabaseModels/Dependencies/GRDB.swift"
    private let grdbLockPath = "input:/repo/DatabaseModels/Dependencies/GRDB.swift.semel-lock"

    private func grdbLock(root: String, fold: String = FolderContentRoot.formatTag) -> String {
        DependencyLock(contentRoot: root, fold: fold, version: "7.11.1",
                       origin: "https://github.com/groue/GRDB.swift.git").text
    }

    /// The conversion of DatabaseModels with GRDB vendored, with `lock` beside it (or none)
    /// and `root` as what its folder folds to.
    private func convertWithVendoredGRDB(lock: String?, root: DataObjectHash = "abc123") throws -> ProcessOutput {
        try convert(packageFolder: "input:/repo/DatabaseModels",
                    json: sourceControlManifest(),
                    externalManifests: [vendoredGRDB: grdbShapedManifest],
                    locks: lock.map { [grdbLockPath: $0] } ?? [:],
                    contentRoots: [vendoredGRDB: root])
    }

    /// Every notice the converter posts while `body` runs.
    private func notices(during body: () throws -> Void) rethrows -> [String] {
        var posted: [String] = []
        let saved = NodeNotice.reporter
        NodeNotice.reporter = { posted.append($0) }
        defer { NodeNotice.reporter = saved }
        try body()
        return posted
    }

    func test_asksForTheLockBesideEveryVendoredPackageAndNoOther() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels", json: sourceControlManifest(),
                                 externalManifests: [vendoredGRDB: grdbShapedManifest])

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.dependencyLocks]).rendered,
                       [grdbLockPath: "StaticFile(path: '\(grdbLockPath)').output"])
    }

    func test_aLockThatMatchesTheFoldersContentRootBuilds() throws {
        let output = try convertWithVendoredGRDB(lock: grdbLock(root: "abc123"), root: "abc123")

        XCTAssertNoThrow(try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput]).expectValue())
        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.dependencyContentRoots]).rendered,
                       [vendoredGRDB: "Folder(path: '\(vendoredGRDB)').pushedContentRoot"],
                       "the pushed root is what the lock is compared with, so it is a wire and a change to it re-runs the check")
        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.dependencyWholeContentRoots]).rendered,
                       [vendoredGRDB: "Folder(path: '\(vendoredGRDB)').contentRoot"])
    }

    /// The graph holds below a vendored folder what a copy's fold never sees — a dot-named
    /// folder, a name the build asked for that nobody pushed — and the comparison leaves
    /// those out. When a lock fails anyway, the message names them, so that what it did not
    /// compare is not mistaken for what differs (B-143). The document carries them, by
    /// reason. A dot-named file holding content is compared, as a push sends it.
    func test_aLockThatDoesNotMatchNamesWhatTheComparisonLeftOut() throws {
        let sources = FolderContentRoot.document(of: [("Lib.swift", .file, .file(hash: "aa", mode: 0o644)),
                                                      (".swiftlint.yml", .file, .file(hash: "bb", mode: 0o644)),
                                                      ("Missing.swift", .file, .notProduced)])
        let dotFolder = FolderContentRoot.document(of: [("ci.yml", .file, .file(hash: "ee", mode: 0o644))])
        let whole = FolderContentRoot.document(of: [("Package.swift", .file, .file(hash: "cc", mode: 0o644)),
                                                    (".github", .folder, .hash(try dotFolder.intern())),
                                                    ("Sources", .folder, .hash(try sources.intern()))])
        let output = try convert(packageFolder: "input:/repo/DatabaseModels", json: sourceControlManifest(),
                                 externalManifests: [vendoredGRDB: grdbShapedManifest],
                                 locks: [grdbLockPath: grdbLock(root: "abc123")],
                                 contentRoots: [vendoredGRDB: "def456"],
                                 wholeContentRoots: [vendoredGRDB: try whole.intern()])

        guard case .lockMismatch(_, _, _, _, let leftOut) = try pendingCondition(output) else {
            return XCTFail("expected a mismatch, got \(try pendingDocument(output))")
        }
        XCTAssertEqual(Set(leftOut), [LeftOutEntry(path: ".github", reason: .dotNamed),
                                      LeftOutEntry(path: "Sources/Missing.swift", reason: .notPushed)])
    }

    // MARK: - A target that names no folder (B-143)

    private let unplacedManifest = """
        {
          "name": "Kit",
          "dependencies": [],
          "products": [{"name": "Kit", "targets": ["Kit"], "type": {"library": ["automatic"]}}],
          "targets": [{"name": "Kit", "type": "regular", "dependencies": []}]
        }
        """

    /// SwiftPM looks under `Sources`, `Source`, `src` and `srcs`, and on a Mac's volume
    /// finds the folder whatever its case; the converter reads where the target is from
    /// the folders' manifests rather than spelling the first guess into a demand.
    func test_aTargetThatNamesNoFolderIsFoundUnderAnyOfSwiftPMsFolders() throws {
        let contents: [String: [FolderManifestEntry]] = [
            "input:/pkg":     [file("Package.swift"), folder("src")],
            "input:/pkg/src": [folder("kit")],
            "input:/pkg/src/kit": [file("Kit.swift")],
        ]
        let output = try convert(json: unplacedManifest, folderContents: contents)

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.targetFolders]).rendered,
                       ["input:/pkg/src/kit": "Folder(path: 'input:/pkg/src/kit').subtreeManifest"])
        let formula = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput]).expectValue().resolveAsString()
        XCTAssertTrue(formula.contains("input:/pkg/src/kit"), formula)
        XCTAssertFalse(formula.contains("input:/pkg/Sources/Kit"), formula)
    }

    /// A target none of those folders holds is the conversion's error, naming where it
    /// looked — and its folder is never asked for, so nothing nobody pushed is made under
    /// the package.
    func test_aTargetNoneOfSwiftPMsFoldersHoldsIsTheConversionsError() throws {
        let contents: [String: [FolderManifestEntry]] = [
            "input:/pkg":         [file("Package.swift"), folder("Sources")],
            "input:/pkg/Sources": [folder("Other")],
        ]
        let output = try convert(json: unplacedManifest, folderContents: contents)

        XCTAssertEqual(try pendingDocument(output),
                       .engine(.targetFolderMissing(package: "Kit", packageFolder: "input:/pkg", target: "Kit"),
                               subject: .target(name: "Kit"),
                               remedy: .missingFolder(tried: ["Sources/Kit", "Source/Kit", "src/Kit", "srcs/Kit"])))
        XCTAssertEqual(output.inputWireSpecs[SwiftFormulaConverter.targetFolders]?.isEmpty ?? true, true)
    }

    /// The whole point: a dependency that moved stops the build, and the document names the
    /// package, both roots, what it was vendored as, and the re-lock as the remedy.
    func test_aLockThatDoesNotMatchStopsTheConversionNamingBothRoots() throws {
        let output = try convertWithVendoredGRDB(lock: grdbLock(root: "abc123"), root: "def456")

        XCTAssertEqual(try pendingDocument(output),
                       .engine(.lockMismatch(folder: vendoredGRDB,
                                             lock: LockFacts(lockPath: grdbLockPath, version: "7.11.1",
                                                             origin: "https://github.com/groue/GRDB.swift.git"),
                                             expected: "sha256:abc123", found: "sha256:def456", leftOut: []),
                               subject: .package(name: "GRDB.swift")))
        XCTAssertEqual(try pendingDocument(output).remedy, .relock(package: "GRDB.swift"))
    }

    /// A root taken under another fold cannot be compared with this one, and saying the
    /// tree moved would be a lie: it may be exactly what was vendored.
    func test_aLockTakenUnderAnotherFoldSaysSoRatherThanThatTheTreeMoved() throws {
        let output = try convertWithVendoredGRDB(lock: grdbLock(root: "abc123", fold: "semel-folder-content-root 1"),
                                                 root: "def456")

        XCTAssertEqual(try pendingCondition(output),
                       .lockFoldChanged(folder: vendoredGRDB,
                                        lock: LockFacts(lockPath: grdbLockPath, version: "7.11.1",
                                                        origin: "https://github.com/groue/GRDB.swift.git"),
                                        lockFold: "semel-folder-content-root 1", currentFold: FolderContentRoot.formatTag))
    }

    func test_aLockThatCannotBeReadStopsTheConversionNamingTheFile() throws {
        let output = try convertWithVendoredGRDB(lock: "content sha256:abc123\n")

        XCTAssertEqual(try pendingCondition(output),
                       .lockUnreadable(folder: vendoredGRDB, lockPath: grdbLockPath, problem: .missingKey(key: "fold")))
    }

    /// Every tree vendored before locks existed, and every one vendored by hand, has none:
    /// the build goes on, says so once, and does not wire the folder's root — so a tree
    /// with no locks is not woken by every edit below its vendored folders.
    func test_aVendoredPackageWithNoLockBuildsAndSaysSo() throws {
        var output: ProcessOutput?
        let posted = try notices {
            output = try convertWithVendoredGRDB(lock: nil)
        }

        let converted = try XCTUnwrap(output)
        XCTAssertNoThrow(try XCTUnwrap(converted.outputValues[SwiftFormulaConverter.formulaOutput]).expectValue())
        XCTAssertEqual(converted.inputWireSpecs[SwiftFormulaConverter.dependencyContentRoots]?.isEmpty, true)
        XCTAssertEqual(posted.count, 1, "said once per conversion, got \(posted)")
        XCTAssertTrue(posted.first?.contains("GRDB.swift") == true, "got \(posted)")
        XCTAssertTrue(posted.first?.contains("semel-swift prepare") == true, "got \(posted)")
    }

    /// The notice is the whole of what a missing lock earns: the error report must not also
    /// name the lock nobody pushed as a file the build is waiting for.
    func test_aLockNobodyPushedIsNotAFileTheBuildNeeds() {
        XCTAssertTrue(SwiftFormulaConverter.descriptor.toleratesAbsentValue(onInputPort: SwiftFormulaConverter.dependencyLocks))
        XCTAssertFalse(SwiftFormulaConverter.descriptor.toleratesAbsentValue(onInputPort: SwiftFormulaConverter.dependencyContentRoots))
    }

    func test_aMatchingLockSaysNothing() throws {
        let posted = try notices {
            _ = try convertWithVendoredGRDB(lock: grdbLock(root: "abc123"), root: "abc123")
        }

        XCTAssertEqual(posted, [])
    }

    /// An Xcode project's formula names a remote package by its vendored folder —
    /// `SwiftFormulaConverter(path: '<root>/Dependencies/keychain-swift', root: <root>)` —
    /// so the package being converted is itself a vendored one, and its lock is checked.
    func test_aPackageConvertedFromTheDependenciesFolderChecksItsOwnLock() throws {
        let output = try convert(packageFolder: "input:/app/Dependencies/keychain-swift", root: "input:/app", json: """
            {
              "name": "KeychainSwift", "dependencies": [],
              "products": [{"name": "KeychainSwift", "targets": ["KeychainSwift"], "type": {"library": ["automatic"]}}],
              "targets": [{"name": "KeychainSwift", "type": "regular", "path": "Sources", "dependencies": []}]
            }
            """)

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.dependencyLocks]).keys.sorted(),
                       ["input:/app/Dependencies/keychain-swift.semel-lock"])
    }

    /// What a pass asks for follows what has arrived, never whether the lock matched. A
    /// demand is a node, and a demanded path that is not in the vendored folder is a ghost
    /// its content root folds: asked for only once the lock passed, it failed the lock, the
    /// failed pass withdrew it, the ghost was collected and the lock passed again — round
    /// and round, a build that never ended (B-133).
    func test_whatAPassAsksForDoesNotDependOnWhetherTheLockMatches() throws {
        let passing = try convertWithVendoredGRDB(lock: grdbLock(root: "abc123"), root: "abc123")
        let failing = try convertWithVendoredGRDB(lock: grdbLock(root: "abc123"), root: "def456")

        XCTAssertNoThrow(try pendingDocument(failing))
        XCTAssertEqual(failing.inputWireSpecs.mapValues(\.rendered), passing.inputWireSpecs.mapValues(\.rendered))
        XCTAssertEqual(failing.inputWireSpecs[SwiftFormulaConverter.targetFolders]?.keys.sorted(),
                       ["\(vendoredGRDB)/GRDB", "input:/repo/DatabaseModels/Sources/DatabaseModels"])
    }

    // MARK: - Binary targets (B-133)

    /// Sparkle's manifest as NetNewsWire vendors it: one product, vending one binary target
    /// SwiftPM downloads by URL. There is no folder for it in the package.
    private let remoteBinaryTarget = """
        {"name": "Sparkle", "type": "binary", "dependencies": [], "exclude": [], "resources": [], "settings": [],
         "url": "https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-for-Swift-Package-Manager.zip",
         "checksum": "4d5de3d3b4ff9b3d1d7c5b1ad1b0a5a1bd6bc7ba7e1d1b2b8b3d0c4b6e2b2d6c"}
        """

    /// The same target by `path:`, an `.xcframework` in the package.
    private let localBinaryTarget = """
        {"name": "Sparkle", "type": "binary", "dependencies": [], "exclude": [], "resources": [], "settings": [],
         "path": "Sparkle.xcframework"}
        """

    private func sparkle(targets: [String], products: String = #"{"name": "Sparkle", "targets": ["Sparkle"], "type": {"library": ["automatic"]}}"#) -> String {
        """
        {
          "name": "Sparkle",
          "dependencies": [],
          "products": [\(products)],
          "targets": [\(targets.joined(separator: ",\n"))]
        }
        """
    }

    /// What a pass published on the formula port, as text: the formula, or the error's
    /// document as it is encoded.
    private func outcome(_ output: ProcessOutput) throws -> String {
        let value = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput])
        switch value {
        case .value(let hash):
            return "formula: " + (try hash.resolveAsString())
        case .noValue(.error(let hash)):
            return "error: " + (try hash.resolveAsString())
        case .noValue(let reason):
            return "no value: \(reason)"
        }
    }

    /// The binary target a pass names as not built.
    private func unbuiltBinaryTarget(_ output: ProcessOutput) throws -> SemelNodeKit.UnbuiltBinaryTarget {
        guard case .binaryTargetNotBuilt(let target) = try pendingCondition(output) else {
            throw XCTSkip("expected a binary target not built, got \(try pendingDocument(output))")
        }
        return target
    }

    /// The conversion from the converter's side of the engine: each pass is given what the
    /// pass before it asked for — every folder answered as the engine answers a path nobody
    /// pushed, an empty folder — until one asks for nothing new. The pass after that must
    /// publish what it did and ask for what it did: a fixed point, which is what lets the
    /// engine settle.
    private func assertSettles(json: String, file: StaticString = #filePath, line: UInt = #line) throws -> ProcessOutput {
        let converter = try makeConverter()
        var inputValues: [String: [String: NodeValue]] = [
            SwiftFormulaConverter.packageFolder: ["folder": .value(try FolderManifest(baseFolderPath: "input:/pkg", entries: []).toJSON().intern())],
            SwiftFormulaConverter.packageJSON:   ["json":   .value(try json.intern())],
        ]
        var output = try converter.process(input: ProcessInput(inputValues: inputValues))
        for _ in 0..<8 {
            var askedForMore = false
            for port in [SwiftFormulaConverter.targetFolders, SwiftFormulaConverter.binaryArtifactFolders] {
                for folder in (output.inputWireSpecs[port] ?? [:]).keys where inputValues[port]?[folder] == nil {
                    inputValues[port, default: [:]][folder] =
                        .value(try FolderSubtreeManifest(entries: []).toJSON().intern())
                    askedForMore = true
                }
            }
            guard askedForMore else {
                break
            }
            output = try converter.process(input: ProcessInput(inputValues: inputValues))
        }
        let again = try converter.process(input: ProcessInput(inputValues: inputValues))

        XCTAssertEqual(try outcome(again), try outcome(output), file: file, line: line)
        XCTAssertEqual(again.inputWireSpecs.mapValues(\.rendered), output.inputWireSpecs.mapValues(\.rendered),
                       file: file, line: line)
        return again
    }

    /// A remote binary target whose artifact `prepare` has not put in the package: the
    /// conversion says where it is expected and what puts it there, the same on every pass.
    func test_aRemoteBinaryTargetNotVendoredNamesWhereItIsExpectedOnEveryPass() throws {
        let output = try assertSettles(json: sparkle(targets: [remoteBinaryTarget]))

        XCTAssertEqual(try pendingDocument(output),
                       .engine(.binaryTargetNotBuilt(target: .init(
                                    package: "Sparkle", packageFolder: "input:/pkg", target: "Sparkle",
                                    artifact: .remote(url: "https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/"
                                                         + "Sparkle-for-Swift-Package-Manager.zip"),
                                    location: .missing(folder: "input:/pkg/semel-artifacts/Sparkle"),
                                    products: ["Sparkle"])),
                               subject: .target(name: "Sparkle")))
        XCTAssertEqual(try pendingDocument(output).remedy, .vendor)
        XCTAssertEqual(output.inputWireSpecs[SwiftFormulaConverter.targetFolders]?.isEmpty, true,
                       "a binary target has no source folder")
        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.binaryArtifactFolders]).rendered,
                       ["input:/pkg": "Folder(path: 'input:/pkg').subtreeManifest"],
                       "the package's own tree, which says it holds no semel-artifacts, and nothing under it")
    }

    /// What a vendored copy with no `semel-artifacts` is asked for: the tree of the package
    /// folder, which is there, and nothing below it — a folder asked for that the copy lacks
    /// would be a ghost its content root folds, and the lock would fail on it (B-133).
    func test_aVendoredPackageIsAskedOnlyForTheArtifactFoldersItLists() throws {
        let vendored = "input:/repo/Dependencies/Sparkle"
        let root = """
            {"name": "App", "dependencies": [{"sourceControl": [{"identity": "sparkle",
                "location": {"remote": [{"urlString": "https://github.com/sparkle-project/Sparkle"}]},
                "requirement": {"range": [{"lowerBound": "2.0.0", "upperBound": "3.0.0"}]}}]}],
             "products": [{"name": "App", "targets": ["App"], "type": {"executable": null}}],
             "targets": [{"name": "App", "type": "executable", "path": "App",
                          "dependencies": [{"product": ["Sparkle", "Sparkle", null, null]}]}]}
            """

        let output = try convert(packageFolder: "input:/repo", json: root,
                                 externalManifests: [vendored: sparkle(targets: [remoteBinaryTarget])])

        XCTAssertEqual(output.inputWireSpecs[SwiftFormulaConverter.binaryArtifactFolders]?.keys.sorted(), [vendored])
        XCTAssertEqual(try unbuiltBinaryTarget(output).location, .missing(folder: "\(vendored)/semel-artifacts/Sparkle"))
    }

    /// Sparkle's own package once `prepare` has vendored its download: its one product
    /// vends only the binary target, so it has no linker, and every func an app names it by
    /// — its frameworks the slice the selector chooses, its modules, objects, link
    /// requirements and bundles empty.
    func test_aRemoteBinaryTargetInSemelArtifactsIsSelectedAndItsProductHasFuncsButNoLinker() throws {
        let formula = try formula(json: sparkle(targets: [remoteBinaryTarget]), folderContents: [
            "input:/pkg": [FolderManifestEntry(name: "semel-artifacts", isFolder: true, isPinned: true)],
            "input:/pkg/semel-artifacts": [FolderManifestEntry(name: "Sparkle", isFolder: true, isPinned: true)],
            "input:/pkg/semel-artifacts/Sparkle": [FolderManifestEntry(name: "Sparkle.xcframework", isFolder: true, isPinned: true)],
        ])

        let slice = try funcDefinition("sliceSparkle", in: formula)
        XCTAssertTrue(slice.contains("XCFrameworkSliceSelector(\n        path: 'input:/pkg/semel-artifacts/Sparkle/Sparkle.xcframework',"), slice)
        XCTAssertTrue(slice.contains("ConfigFilter(prefix: 'swift.linker'"), "the slice is chosen for the platform the linker links for: \(slice)")
        XCTAssertTrue(slice.contains("infoPlist: ['Info.plist': StaticFile(path: 'input:/pkg/semel-artifacts/Sparkle/Sparkle.xcframework/Info.plist').output]"), slice)
        XCTAssertEqual(try funcDefinition("frameworks_Sparkle", in: formula),
                       "func frameworks_Sparkle() =\n    TreeMerger(input: [\n        'Sparkle': sliceSparkle().frameworks\n    ]).files")
        XCTAssertEqual(try funcDefinition("embedded_Sparkle", in: formula),
                       "func embedded_Sparkle() =\n    TreeMerger(input: [\n        'Sparkle': sliceSparkle().embeddedFrameworks\n    ]).files",
                       "what an app embeds is the dynamic frameworks alone, which the selector decides (B-77 item 12)")
        XCTAssertTrue(try funcDefinition("objects_Sparkle", in: formula).contains("'Sparkle': sliceSparkle().libraries"), formula)
        XCTAssertTrue(try funcDefinition("modules_Sparkle", in: formula)
                        .contains("'Sparkle': TreeMerger(under: 'Sparkle', input: ['headers': sliceSparkle().headers]).files"), formula)
        XCTAssertNoThrow(try funcDefinition("linking_Sparkle", in: formula))
        XCTAssertNoThrow(try funcDefinition("bundles_Sparkle", in: formula))
        XCTAssertFalse(formula.contains("SwiftLinker"), formula)
        XCTAssertFalse(formula.contains("SwiftCompiler"), formula)
        XCTAssertLessThan(try XCTUnwrap(formula.range(of: "func sliceSparkle()")).lowerBound,
                          try XCTUnwrap(formula.range(of: "func frameworks_Sparkle()")).lowerBound,
                          "a func is defined before the funcs that name it")
    }

    /// A binary target by `path:` is its own `.xcframework` folder, asked for directly.
    func test_aLocalXCFrameworkIsSelectedWhereItIs() throws {
        let formula = try formula(json: sparkle(targets: [localBinaryTarget]), folderContents: [
            "input:/pkg/Sparkle.xcframework": [FolderManifestEntry(name: "Info.plist", isFolder: false, isPinned: true),
                                               FolderManifestEntry(name: "macos-arm64", isFolder: true, isPinned: true)],
        ])

        XCTAssertTrue(try funcDefinition("sliceSparkle", in: formula).contains("path: 'input:/pkg/Sparkle.xcframework',"), formula)
        XCTAssertTrue(formula.contains("func frameworks_Sparkle()"), formula)
    }

    /// A `path:` xcframework whose folder holds nothing is named as missing.
    func test_aLocalXCFrameworkThatIsNotThereIsNamed() throws {
        let target = try unbuiltBinaryTarget(try assertSettles(json: sparkle(targets: [localBinaryTarget])))

        XCTAssertEqual(target.artifact, .local(path: "Sparkle.xcframework"))
        XCTAssertEqual(target.location, .missing(folder: "input:/pkg/Sparkle.xcframework"))
    }

    /// A `path:` zip is where `prepare` unzips it, and named as not unzipped when it is not.
    func test_aLocalZipIsReadFromSemelArtifacts() throws {
        let zipped = #"{"name": "Sparkle", "type": "binary", "dependencies": [], "path": "Sparkle.xcframework.zip"}"#
        let target = try unbuiltBinaryTarget(try assertSettles(json: sparkle(targets: [zipped])))
        XCTAssertEqual(target.artifact, .zip(path: "Sparkle.xcframework.zip"))
        XCTAssertEqual(target.location, .missing(folder: "input:/pkg/semel-artifacts/Sparkle"))

        let formula = try formula(json: sparkle(targets: [zipped]), folderContents: [
            "input:/pkg": [FolderManifestEntry(name: "semel-artifacts", isFolder: true, isPinned: true)],
            "input:/pkg/semel-artifacts": [FolderManifestEntry(name: "Sparkle", isFolder: true, isPinned: true)],
            "input:/pkg/semel-artifacts/Sparkle": [FolderManifestEntry(name: "Sparkle.xcframework", isFolder: true, isPinned: true)],
        ])
        XCTAssertTrue(formula.contains("path: 'input:/pkg/semel-artifacts/Sparkle/Sparkle.xcframework',"), formula)
    }

    /// What is still not built (B-133): an artifact that is not an `.xcframework` — an
    /// `.artifactbundle` holds executables for plugins, not a library to link.
    func test_anArtifactThatIsNotAnXCFrameworkIsNotBuiltAndSaysSo() throws {
        let bundle = #"{"name": "Lint", "type": "binary", "dependencies": [], "path": "Lint.artifactbundle"}"#
        let json = sparkle(targets: [bundle], products: #"{"name": "Lint", "targets": ["Lint"], "type": {"library": ["automatic"]}}"#)

        let target = try unbuiltBinaryTarget(try assertSettles(json: json))

        XCTAssertEqual(target.location, .notAnXCFramework(path: "input:/pkg/Lint.artifactbundle", contents: []))
        XCTAssertEqual(target.products, ["Lint"])
    }

    /// A Swift target depending on a binary one compiles against its framework slice, and a
    /// product linking it links the framework and finds it beside itself at run time.
    func test_aSwiftTargetReachingABinaryTargetCompilesAndLinksAgainstItsSlice() throws {
        let json = sparkle(targets: [#"{"name": "Updater", "type": "executable", "path": "Sources/Updater", "dependencies": [{"byName": ["Sparkle", null]}]}"#,
                                     localBinaryTarget],
                           products: #"{"name": "Updater", "targets": ["Updater"], "type": {"executable": null}}"#)

        let formula = try formula(json: json, folderContents: [
            "input:/pkg/Sparkle.xcframework": [FolderManifestEntry(name: "Info.plist", isFolder: false, isPinned: true)],
        ])

        let compiler = try funcDefinition("compilerUpdater", in: formula)
        XCTAssertTrue(compiler.contains("frameworkTrees: [\n            'Sparkle': sliceSparkle().frameworks\n    ]"), compiler)
        XCTAssertTrue(compiler.contains("'Sparkle': TreeMerger(under: 'Sparkle', input: ['headers': sliceSparkle().headers]).files"), compiler)
        let linker = try productBlock("Updater", in: formula)
        XCTAssertTrue(linker.contains("frameworksRunpath: '@loader_path'"), linker)
        XCTAssertTrue(linker.contains("frameworkTrees: ['Updater': frameworks_Updater().files]"), linker)
        XCTAssertTrue(linker.contains("objectTrees: [\n            'Sparkle': sliceSparkle().libraries\n        ]"), linker)
    }

    /// A binary target no product reaches is not needed: the formula is made, and nothing
    /// is compiled from it.
    func test_aBinaryTargetNoProductReachesIsLeftOut() throws {
        let json = sparkle(targets: [#"{"name": "Updater", "type": "regular", "path": "Sources/Updater", "dependencies": []}"#,
                                     localBinaryTarget],
                           products: #"{"name": "Updater", "targets": ["Updater"], "type": {"library": ["automatic"]}}"#)

        let result = try formula(json: json)

        XCTAssertTrue(result.contains("func compilerUpdater()"), "got:\n\(result)")
        XCTAssertFalse(result.contains("sliceSparkle"), "got:\n\(result)")
        XCTAssertFalse(result.contains("Sparkle.xcframework"), "got:\n\(result)")
    }

    // MARK: - sourceControl dependencies

    /// This build system never fetches anything, so a git dependency is resolved to a
    /// copy vendored under the root package's `Dependencies` folder — flat, one copy per
    /// package, where `semel-swift` puts it. The name comes from the URL, not from SPM's
    /// `identity` — identity is lowercased ("grdb.swift") and so cannot name a directory
    /// on a case-sensitive filesystem.
    func test_resolvesASourceControlDependencyToTheRootsDependenciesFolder() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels", json: sourceControlManifest())

        XCTAssertEqual(try externalSpecs(output).keys.sorted(), ["input:/repo/DatabaseModels/Dependencies/GRDB.swift"])
    }

    func test_readsThePackageManifestOfAVendoredSourceControlDependency() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels", json: sourceControlManifest())

        let spec = try XCTUnwrap(try externalSpecs(output)["input:/repo/DatabaseModels/Dependencies/GRDB.swift"])
        XCTAssertTrue(spec.contains("input:/repo/DatabaseModels/Dependencies/GRDB.swift/Package.swift"), "got: \(spec)")
    }

    /// The end of the chain: once the vendored manifest arrives, the dependency's product
    /// resolves to a real target and its swiftmodule is wired into the compile. Without
    /// this the target compiles alone and fails with "no such module 'GRDB'".
    func test_wiresTheModuleOfAVendoredSourceControlDependency() throws {
        let result = try formula(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest(),
                                 externalManifests: ["input:/repo/DatabaseModels/Dependencies/GRDB.swift": grdbShapedManifest])

        XCTAssertTrue(result.contains("'GRDB': compilerGRDB().swiftmodule"), "got:\n\(result)")
        XCTAssertTrue(result.contains("Folder(path: 'input:/repo/DatabaseModels/Dependencies/GRDB.swift/GRDB').manifest"),
                      "GRDB's sources should resolve against the vendored root, got:\n\(result)")
    }

    func test_stripsTheGitSuffixWhenNamingTheVendoredDirectory() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest(url: "https://github.com/groue/GRDB.swift"))

        XCTAssertEqual(try externalSpecs(output).keys.sorted(), ["input:/repo/DatabaseModels/Dependencies/GRDB.swift"])
    }

    func test_resolvesScpStyleGitURLs() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest(url: "git@github.com:groue/GRDB.swift.git"))

        XCTAssertEqual(try externalSpecs(output).keys.sorted(), ["input:/repo/DatabaseModels/Dependencies/GRDB.swift"])
    }

    /// A package dependency of a package dependency still has to resolve, and every
    /// vendored checkout lives under the *root's* `Dependencies` folder whatever package
    /// named it — so the walk resolves a sourceControl URL against the root, not against
    /// the manifest that declared it. One copy per package, at any depth.
    func test_resolvesASourceControlDependencyDeclaredByAnExternalPackage() throws {
        let output = try convert(packageFolder: "input:/repo/SemelCore", json: """
            {
              "name": "SemelCore",
              "dependencies": [{"fileSystem": [{"identity": "databasemodels", "path": "../DatabaseModels"}]}],
              "products": [
                {"name": "SemelCore", "targets": ["SemelCore"], "type": {"library": ["automatic"]}}
              ],
              "targets": [
                {"name": "SemelCore", "type": "regular", "path": "Sources/SemelCore",
                 "dependencies": [{"product": ["DatabaseModels", "DatabaseModels", null, null]}]}
              ]
            }
            """,
            externalManifests: ["input:/repo/DatabaseModels": sourceControlManifest()])

        XCTAssertEqual(try externalSpecs(output).keys.sorted(),
                       ["input:/repo/DatabaseModels", "input:/repo/SemelCore/Dependencies/GRDB.swift"])
    }

    // MARK: - Name collisions across vendored packages (B-04)

    /// An app that names one product two vendored packages both vend. SPM would reject the
    /// graph; the converter must at least resolve it the same way in every process, or the
    /// formula — and every graphSpec derived from it — changes on restart.
    private let appNamingSharedProduct = """
        {
          "name": "App",
          "dependencies": [{"fileSystem": [{"identity": "a", "path": "../A"}]},
                           {"fileSystem": [{"identity": "b", "path": "../B"}]}],
          "products": [{"name": "App", "targets": ["App"], "type": {"executable": null}}],
          "targets": [{"name": "App", "type": "executable", "path": "App",
                       "dependencies": [{"product": ["Shared", "A", null, null]}]}]
        }
        """

    private func packageVending(product: String, fromTarget target: String) -> String {
        """
        {
          "name": "\(product)",
          "dependencies": [],
          "products": [{"name": "\(product)", "targets": ["\(target)"], "type": {"library": ["automatic"]}}],
          "targets": [{"name": "\(target)", "type": "regular", "path": "Sources/\(target)", "dependencies": []}]
        }
        """
    }

    /// Two vendored packages vend a product of the same name from differently named
    /// targets. The package at the lexically first folder wins, whatever order the
    /// manifests were handed over in.
    func test_resolvesAProductVendedByTwoPackagesToTheLexicallyFirstFolder() throws {
        let result = try formula(packageFolder: "input:/repo/App",
                                 json: appNamingSharedProduct,
                                 externalManifests: ["input:/repo/B": packageVending(product: "Shared", fromTarget: "SharedB"),
                                                     "input:/repo/A": packageVending(product: "Shared", fromTarget: "SharedA")])

        let block = try funcDefinition("compilerApp", in: result)
        XCTAssertTrue(block.contains("'SharedA': compilerSharedA().swiftmodule"), "got:\n\(block)")
        XCTAssertFalse(result.contains("compilerSharedB"), "got:\n\(result)")
    }

    /// Two vendored packages define a *target* of the same name. Same rule: the lexically
    /// first folder supplies the sources.
    func test_resolvesATargetDefinedByTwoPackagesToTheLexicallyFirstFolder() throws {
        let result = try formula(packageFolder: "input:/repo/App",
                                 json: appNamingSharedProduct,
                                 externalManifests: ["input:/repo/B": packageVending(product: "Shared", fromTarget: "Shared"),
                                                     "input:/repo/A": packageVending(product: "Shared", fromTarget: "Shared")])

        let block = try funcDefinition("compilerShared", in: result)
        XCTAssertTrue(block.contains("Folder(path: 'input:/repo/A/Sources/Shared').manifest"), "got:\n\(block)")
        XCTAssertFalse(block.contains("input:/repo/B/"), "got:\n\(block)")
    }

    // MARK: - registry dependencies (B-07)

    /// What `swift package dump-package` emits for `.package(id: "mona.LinkedList", from:)`.
    /// A registry identity is `scope.name`, case preserved — unlike a git identity, which
    /// is lowercased — so it can name a directory.
    private let registryManifest = """
        {
          "name": "App",
          "dependencies": [
            {"registry": [{"identity": "mona.LinkedList",
                           "requirement": {"range": [{"lowerBound": "1.0.0", "upperBound": "2.0.0"}]}}]}
          ],
          "products": [{"name": "App", "targets": ["App"], "type": {"executable": null}}],
          "targets": [{"name": "App", "type": "executable", "path": "Sources/App",
                       "dependencies": [{"product": ["LinkedList", "mona.LinkedList", null, null]}]}]
        }
        """

    /// A registry dependency was silently dropped: the build reached the compiler and
    /// failed there with "no such module". It resolves like a git dependency — under the
    /// root's `Dependencies` folder — named by its identity.
    func test_resolvesARegistryDependencyToTheDependenciesFolderNamedByItsIdentity() throws {
        let output = try convert(packageFolder: "input:/repo/App", json: registryManifest)

        XCTAssertEqual(try externalSpecs(output).keys.sorted(), ["input:/repo/App/Dependencies/mona.LinkedList"])
    }

    func test_explainsWhichRegistryPackageAVendoredPathIsWaitingFor() throws {
        let condition = try pendingCondition(try convert(packageFolder: "input:/repo/App", json: registryManifest))

        XCTAssertEqual(condition, .packageNotPresent(path: "input:/repo/App/Dependencies/mona.LinkedList",
                                                     origin: .registry(identity: "mona.LinkedList")))
    }

    func test_wiresTheModuleOfAVendoredRegistryDependency() throws {
        let result = try formula(packageFolder: "input:/repo/App",
                                 json: registryManifest,
                                 externalManifests: ["input:/repo/App/Dependencies/mona.LinkedList":
                                                        packageVending(product: "LinkedList", fromTarget: "LinkedList")])

        let block = try funcDefinition("compilerApp", in: result)
        XCTAssertTrue(block.contains("'LinkedList': compilerLinkedList().swiftmodule"), "got:\n\(block)")
        XCTAssertTrue(result.contains("Folder(path: 'input:/repo/App/Dependencies/mona.LinkedList/Sources/LinkedList').manifest"),
                      "got:\n\(result)")
    }

    // MARK: - Language mode

    /// `.swiftLanguageMode(.v6)` on a target is a fact about the target, like its module
    /// name: dropped, the code compiles in Swift 5 mode with different diagnostics. It
    /// travels as a manifest-derived literal so a config file cannot override it.
    func test_carriesTheTargetsLanguageModeIntoTheCompilerConfiguration() throws {
        let result = try formula(json: """
            {
              "name": "Models",
              "dependencies": [],
              "products": [{"name": "Models", "targets": ["Models"], "type": {"library": ["automatic"]}}],
              "targets": [
                {"name": "Models", "type": "regular", "path": "Sources/Models", "dependencies": [],
                 "settings": [{"kind": {"swiftLanguageMode": {"_0": "6"}}, "tool": "swift"}]}
              ]
            }
            """)

        XCTAssertTrue(result.contains("languageMode: '6'"), "got:\n\(result)")
    }

    func test_omitsTheLanguageModeWhenTheTargetDeclaresNone() throws {
        let result = try formula(json: """
            {
              "name": "Models",
              "dependencies": [],
              "products": [{"name": "Models", "targets": ["Models"], "type": {"library": ["automatic"]}}],
              "targets": [{"name": "Models", "type": "regular", "path": "Sources/Models", "dependencies": []}]
            }
            """)

        XCTAssertFalse(result.contains("languageMode"), "got:\n\(result)")
    }

    /// A target declaring no mode compiles in its package's, as SwiftPM decides it: every
    /// NetNewsWire package is `swift-tools-version:6.2`, so Swift 6, and swiftc's default
    /// is 5 — where `-warnings-as-errors` turns its warning that a module interface wants a
    /// language mode into the error that stopped `RSWeb` (B-77).
    func test_aTargetWithNoLanguageModeTakesItsPackagesFromTheToolsVersion() throws {
        func manifest(toolsVersion: String, modes: String = "null", settings: String = "[]") -> String {
            """
            {
              "name": "Models",
              "dependencies": [],
              "toolsVersion": {"_version": "\(toolsVersion)"},
              "swiftLanguageVersions": \(modes),
              "products": [{"name": "Models", "targets": ["Models"], "type": {"library": ["automatic"]}}],
              "targets": [{"name": "Models", "type": "regular", "path": "Sources/Models", "dependencies": [],
                           "settings": \(settings)}]
            }
            """
        }
        func mode(_ json: String) throws -> String? {
            let block = try funcDefinition("compilerModels", in: try formula(json: json))
            return block.range(of: #"languageMode: '[^']*'"#, options: .regularExpression).map {
                String(block[$0].dropFirst("languageMode: '".count).dropLast())
            }
        }

        XCTAssertEqual(try mode(manifest(toolsVersion: "6.2.0")), "6")
        XCTAssertEqual(try mode(manifest(toolsVersion: "5.9.0")), "5")
        XCTAssertEqual(try mode(manifest(toolsVersion: "4.2.0")), "4.2")
        XCTAssertEqual(try mode(manifest(toolsVersion: "6.0.0", modes: #"["5", "4.2"]"#)), "5",
                       "the highest declared mode, not the tools version's")
        XCTAssertEqual(try mode(manifest(toolsVersion: "5.9.0", modes: #"["7", "5"]"#)), "5",
                       "a mode this compiler lacks is not chosen")
        XCTAssertEqual(try mode(manifest(toolsVersion: "6.2.0",
                                         settings: #"[{"kind": {"swiftLanguageMode": {"_0": "5"}}, "tool": "swift"}]"#)), "5",
                       "the target's own mode wins")
    }

    // MARK: - Swift settings

    /// A target's `swiftSettings` as `dump-package` writes them, every kind the compiler
    /// takes, one conditional on each platform and one on a configuration.
    private let swiftSettingsManifest = """
        {
          "name": "Models",
          "dependencies": [],
          "products": [{"name": "Models", "targets": ["Models"], "type": {"library": ["automatic"]}}],
          "targets": [
            {"name": "Models", "type": "regular", "path": "Sources/Models", "dependencies": [],
             "settings": [
               {"kind": {"enableUpcomingFeature": {"_0": "NonisolatedNonsendingByDefault"}}, "tool": "swift"},
               {"condition": {"platformNames": ["ios"]}, "kind": {"enableUpcomingFeature": {"_0": "InferIsolatedConformances"}}, "tool": "swift"},
               {"kind": {"enableExperimentalFeature": {"_0": "StrictConcurrency"}}, "tool": "swift"},
               {"kind": {"define": {"_0": "FOO"}}, "tool": "swift"},
               {"condition": {"platformNames": ["macos"]}, "kind": {"define": {"_0": "MAC"}}, "tool": "swift"},
               {"condition": {"config": "debug", "platformNames": []}, "kind": {"define": {"_0": "DEBUGONLY"}}, "tool": "swift"},
               {"kind": {"unsafeFlags": {"_0": ["-warnings-as-errors", "-Xcc", "-Wl,-a"]}}, "tool": "swift"},
               {"kind": {"swiftLanguageMode": {"_0": "6"}}, "tool": "swift"},
               {"kind": {"strictMemorySafety": {}}, "tool": "swift"},
               {"kind": {"define": {"_0": "CONLY"}}, "tool": "c"}
             ]}
          ]
        }
        """

    /// NetNewsWire's packages: `NonisolatedNonsendingByDefault` decides which actor a
    /// `nonisolated` async method runs on, and a caller's compile reads that back from the
    /// module, so the feature has to reach the package's compiler (B-77 item 16). Each
    /// kind is a literal of its own; a setting conditional on a platform is decided for
    /// the SDK the linker links against, as a linker setting is, and one conditional on a
    /// configuration is not carried.
    func test_aTargetsSwiftSettingsReachItsCompilerDecidedForThePlatform() throws {
        let waiting = try convert(json: swiftSettingsManifest)
        XCTAssertNotNil(waiting.inputWireSpecs[SwiftFormulaConverter.linkerConfiguration]?[SwiftLinkerConfiguration.settingNamespace],
                        "a platform-conditional Swift setting asks for the platform")
        XCTAssertEqual(try pendingCondition(waiting), .inputsWithoutValue(kind: .platformSettings, paths: ["swift.linker"]))

        let forMac = try funcDefinition("compilerModels", in: try formula(json: swiftSettingsManifest,
                                                                          linkerSettings: "target=arm64-apple-macosx15.0"))
        XCTAssertTrue(forMac.contains("defines: 'SWIFT_PACKAGE,FOO,MAC', "
                                      + "experimentalFeatures: 'StrictConcurrency', "
                                      + "languageMode: '6', "
                                      + "moduleName: 'Models', "
                                      + "packageName: 'Models', "
                                      + #"unsafeFlags: '["-warnings-as-errors","-Xcc","-Wl,-a"]', "#
                                      + "upcomingFeatures: 'NonisolatedNonsendingByDefault'"), "got:\n\(forMac)")

        let forIOS = try funcDefinition("compilerModels", in: try formula(json: swiftSettingsManifest,
                                                                          linkerSettings: "sdk=iphonesimulator"))
        XCTAssertTrue(forIOS.contains("defines: 'SWIFT_PACKAGE,FOO', "), "got:\n\(forIOS)")
        XCTAssertTrue(forIOS.contains("upcomingFeatures: 'NonisolatedNonsendingByDefault,InferIsolatedConformances'"),
                      "got:\n\(forIOS)")
    }

    /// A dependency conditional on platforms — LanguageClient's `.product(name: "ProcessEnv",
    /// …, condition: .when(platforms: [.macOS]))` — is one where it holds and nowhere else,
    /// and the conversion asks for the platform to know (B-77). It was dropped everywhere:
    /// its condition, an object among the strings, failed the decoding of the whole entry.
    func test_aDependencyConditionalOnPlatformsIsOneWhereItHolds() throws {
        let json = """
            {
              "name": "Client",
              "dependencies": [],
              "products": [{"name": "Client", "targets": ["Client"], "type": {"library": ["automatic"]}}],
              "targets": [
                {"name": "Client", "type": "regular", "path": "Sources/Client",
                 "dependencies": [{"target": ["MacOnly", {"platformNames": ["macos"]}]},
                                  {"byName": ["Anywhere", {"config": "debug", "platformNames": []}]},
                                  {"byName": ["Shared", null]}]},
                {"name": "MacOnly", "type": "regular", "path": "Sources/MacOnly", "dependencies": []},
                {"name": "Anywhere", "type": "regular", "path": "Sources/Anywhere", "dependencies": []},
                {"name": "Shared", "type": "regular", "path": "Sources/Shared", "dependencies": []}
              ]
            }
            """
        let waiting = try convert(json: json)
        XCTAssertNotNil(waiting.inputWireSpecs[SwiftFormulaConverter.linkerConfiguration]?[SwiftLinkerConfiguration.settingNamespace],
                        "a platform-conditional dependency asks for the platform")

        let forMac = try funcDefinition("compilerClient", in: try formula(json: json, linkerSettings: "sdk=macosx"))
        XCTAssertTrue(forMac.contains("'MacOnly': compilerMacOnly().swiftmodule"), "got:\n\(forMac)")
        XCTAssertTrue(forMac.contains("'Anywhere': compilerAnywhere().swiftmodule"), "got:\n\(forMac)")
        XCTAssertTrue(forMac.contains("'Shared': compilerShared().swiftmodule"), "got:\n\(forMac)")

        let forIOS = try funcDefinition("compilerClient", in: try formula(json: json, linkerSettings: "sdk=iphonesimulator"))
        XCTAssertFalse(forIOS.contains("MacOnly"), "got:\n\(forIOS)")
        XCTAssertTrue(forIOS.contains("'Anywhere': compilerAnywhere().swiftmodule"),
                      "a condition on a configuration alone holds on every platform, got:\n\(forIOS)")
    }

    /// A target's build-tool plugins — SwiftLint's, on CodeEdit's packages — are not run,
    /// and the conversion says which, once, rather than dropping them unsaid (B-77). A test
    /// target's are not named: no test target is built.
    func test_theBuildToolPluginsTheTargetsNameAreNamedAsNotRun() throws {
        let json = """
            {
              "name": "TextView",
              "dependencies": [],
              "products": [{"name": "TextView", "targets": ["TextView"], "type": {"library": ["automatic"]}}],
              "targets": [
                {"name": "TextView", "type": "regular", "path": "Sources/TextView", "dependencies": [],
                 "pluginUsages": [{"plugin": ["SwiftLint", "SwiftLintPlugin"]}, {"plugin": ["Generate", null]}]},
                {"name": "TextViewTests", "type": "test", "path": "Tests/TextViewTests", "dependencies": [],
                 "pluginUsages": [{"plugin": ["SwiftLint", "SwiftLintPlugin"]}]}
              ]
            }
            """
        var result = ""
        let posted = try notices { result = try formula(json: json) }

        XCTAssertEqual(posted, ["Build-tool plugins are not run (B-77): SwiftLint (SwiftLintPlugin), Generate on TextView. "
                                + "Each target builds without what its plugins would do."])
        XCTAssertTrue(result.contains("func compilerTextView()"), "the target builds without them, got:\n\(result)")
        XCTAssertEqual(try notices { _ = try formula(json: swiftSettingsManifest, linkerSettings: "sdk=macosx") }, [],
                       "no plugin, nothing said")
    }

    /// A target whose sources only its plugins would generate has nothing to compile, as no
    /// plugin is run (B-77): the conversion stops and names the target, its package and its
    /// plugins, rather than hand `swiftc` an empty folder. A `.swift` file the target's
    /// `exclude:` leaves out is not its own; one it keeps is, and the target compiles.
    func test_aTargetWhoseSourcesOnlyAPluginWouldMakeFailsNamingThePlugin() throws {
        func manifest(exclude: [String]) -> String {
            let excluded = exclude.map { "\"\($0)\"" }.joined(separator: ", ")
            return """
                {
                  "name": "Gen",
                  "dependencies": [],
                  "products": [{"name": "Gen", "targets": ["Gen"], "type": {"library": ["automatic"]}}],
                  "targets": [
                    {"name": "Gen", "type": "regular", "path": "Sources/Gen", "dependencies": [{"byName": ["Schema", null]}]},
                    {"name": "Schema", "type": "regular", "path": "Sources/Schema", "dependencies": [], "exclude": [\(excluded)],
                     "pluginUsages": [{"plugin": ["Generate", "GenPlugin"]}, {"plugin": ["Stamp", null]}]}
                  ]
                }
                """
        }
        let schemaFolder = [
            "input:/pkg/Sources/Schema": [FolderManifestEntry(name: "schema.graphql", isFolder: false, isPinned: true),
                                          FolderManifestEntry(name: "Old", isFolder: true, isPinned: true)],
            "input:/pkg/Sources/Schema/Old": [FolderManifestEntry(name: "Legacy.swift", isFolder: false, isPinned: true)],
        ]

        let failed = try convert(json: manifest(exclude: ["Old"]), folderContents: schemaFolder)
        XCTAssertEqual(try pendingDocument(failed),
                       .engine(.sourcesOnlyFromPlugins(package: "Gen", target: "Schema", plugins: ["Generate (GenPlugin)", "Stamp"]),
                               subject: .target(name: "Schema")))

        let built = try outcome(try convert(json: manifest(exclude: []), folderContents: schemaFolder))
        XCTAssertTrue(built.hasPrefix("formula: ") && built.contains("func compilerSchema()"),
                      "Old/Legacy.swift is the target's own when nothing excludes it, got:\n\(built)")
    }

    // MARK: - Macros (B-80)

    /// A package with a macro over swift-syntax's shape: a C target under the Swift ones, a
    /// library declaring the macro, and an executable using it through the library.
    private let macroPackage = """
        {
          "name": "Stringify",
          "dependencies": [{"fileSystem": [{"identity": "swift-syntax", "path": "../swift-syntax"}]}],
          "products": [{"name": "App", "targets": ["App"], "type": {"executable": null}},
                       {"name": "Stringify", "targets": ["Stringify"], "type": {"library": ["automatic"]}}],
          "targets": [
            {"name": "StringifyMacros", "type": "macro", "path": "Sources/StringifyMacros",
             "dependencies": [{"product": ["SwiftSyntaxMacros", "swift-syntax", null, null]},
                              {"product": ["SwiftCompilerPlugin", "swift-syntax", null, null]}]},
            {"name": "Stringify", "type": "regular", "path": "Sources/Stringify",
             "dependencies": [{"byName": ["StringifyMacros", null]}]},
            {"name": "App", "type": "executable", "path": "Sources/App", "dependencies": [{"byName": ["Stringify", null]}]}
          ]
        }
        """

    private let swiftSyntaxShapedPackage = """
        {
          "name": "swift-syntax",
          "dependencies": [],
          "products": [{"name": "SwiftSyntaxMacros", "targets": ["SwiftSyntaxMacros"], "type": {"library": ["automatic"]}},
                       {"name": "SwiftCompilerPlugin", "targets": ["SwiftCompilerPlugin"], "type": {"library": ["automatic"]}}],
          "targets": [
            {"name": "_SwiftSyntaxCShims", "type": "regular", "path": "Sources/_SwiftSyntaxCShims", "dependencies": []},
            {"name": "SwiftSyntax", "type": "regular", "path": "Sources/SwiftSyntax",
             "dependencies": [{"byName": ["_SwiftSyntaxCShims", null]}]},
            {"name": "SwiftSyntaxMacros", "type": "regular", "path": "Sources/SwiftSyntaxMacros",
             "dependencies": [{"byName": ["SwiftSyntax", null]}]},
            {"name": "SwiftCompilerPlugin", "type": "regular", "path": "Sources/SwiftCompilerPlugin",
             "dependencies": [{"byName": ["SwiftSyntaxMacros", null]}]}
          ]
        }
        """

    private func macroConversion(linkerSettings: String?) throws -> ProcessOutput {
        try convert(packageFolder: "input:/repo/Stringify", json: macroPackage,
                    externalManifests: ["input:/repo/swift-syntax": swiftSyntaxShapedPackage],
                    folderContents: ["input:/repo/swift-syntax/Sources/_SwiftSyntaxCShims":         [file("dummy.c"), folder("include")],
                                     "input:/repo/swift-syntax/Sources/_SwiftSyntaxCShims/include": [file("_includes.h")]],
                    linkerSettings: linkerSettings)
    }

    private func macroFormula() throws -> String {
        try XCTUnwrap(macroConversion(linkerSettings: "sdk=macosx").outputValues[SwiftFormulaConverter.formulaOutput])
            .expectValue().resolveAsString()
    }

    /// A macro target is compiled as a library is, against the swift-syntax targets it
    /// reaches, and linked with them — the C one through the clang nodes — into an
    /// executable of its own, defined once however many products reach it.
    func test_aMacroTargetIsLinkedIntoAnExecutableWithWhatItReaches() throws {
        let result = try macroFormula()

        let executable = try funcDefinition("macroExecutableStringifyMacros", in: result)
        XCTAssertTrue(executable.contains("SwiftLinker("), "got:\n\(executable)")
        XCTAssertTrue(executable.contains("linkage: 'executable'"), "got:\n\(executable)")
        XCTAssertTrue(executable.contains("outputName: 'StringifyMacros'"), "got:\n\(executable)")
        for object in ["'StringifyMacros.o': compilerStringifyMacros().object", "'SwiftSyntax.o': compilerSwiftSyntax().object",
                       "'SwiftSyntaxMacros.o': compilerSwiftSyntaxMacros().object",
                       "'SwiftCompilerPlugin.o': compilerSwiftCompilerPlugin().object",
                       "{f: 'input:/repo/swift-syntax/Sources/_SwiftSyntaxCShims/**/*.c'} \"%%f%%.o\": ClangCompiler("] {
            XCTAssertTrue(executable.contains(object), "\(object) is linked into the macro, got:\n\(executable)")
        }
        XCTAssertEqual(result.components(separatedBy: "func macroExecutableStringifyMacros()").count, 2,
                       "defined once for the two products that reach it, got:\n\(result)")

        let compiler = try funcDefinition("compilerStringifyMacros", in: result)
        XCTAssertFalse(compiler.contains("parseAsLibrary"), "a macro compiles as a library, its @main the entry, got:\n\(compiler)")
        XCTAssertTrue(compiler.contains("'SwiftCompilerPlugin': compilerSwiftCompilerPlugin().swiftmodule"), "got:\n\(compiler)")
        XCTAssertTrue(compiler.contains("'_SwiftSyntaxCShims': headers_SwiftSyntaxCShims().files"),
                      "the C target's headers reach it, got:\n\(compiler)")
    }

    /// Every compile reaching the macro loads its executable, keyed by the macro's module —
    /// the library declaring the macro and, through it, the executable that expands it — and
    /// none imports the macro's module or swift-syntax's, which run in the macro alone.
    func test_everyTargetReachingAMacroLoadsItsExecutable() throws {
        let result = try macroFormula()

        let wire = "macroExecutables: [\n            'StringifyMacros': macroExecutableStringifyMacros().output\n    ]"
        for target in ["Stringify", "App"] {
            let compiler = try funcDefinition("compiler\(target)", in: result)
            XCTAssertTrue(compiler.contains(wire), "got:\n\(compiler)")
            XCTAssertFalse(compiler.contains("compilerStringifyMacros()"), "got:\n\(compiler)")
            XCTAssertFalse(compiler.contains("compilerSwiftSyntax()"), "got:\n\(compiler)")
            XCTAssertFalse(compiler.contains("headers_SwiftSyntaxCShims"), "got:\n\(compiler)")
        }
        XCTAssertFalse(try funcDefinition("compilerStringifyMacros", in: result).contains("macroExecutables"),
                       "a macro loads no macro of its own")
        // Defined before the compiles that name it.
        let executableAt = try XCTUnwrap(result.range(of: "func macroExecutableStringifyMacros()")).lowerBound
        let compilerAt   = try XCTUnwrap(result.range(of: "func compilerStringify()")).lowerBound
        XCTAssertLessThan(executableAt, compilerAt)
    }

    /// What a product links and what it vends for import stop at the macro: its objects and
    /// swift-syntax's are the macro's executable, not the product's.
    func test_aProductLinksAndVendsNothingOfTheMacrosItsTargetsUse() throws {
        let result = try macroFormula()

        let product = try productBlock("App", in: result)
        XCTAssertTrue(product.contains("'App.o': compilerApp().object"), "got:\n\(product)")
        XCTAssertTrue(product.contains("'Stringify.o': compilerStringify().object"), "got:\n\(product)")
        for absent in ["StringifyMacros.o", "SwiftSyntax", "ClangCompiler("] {
            XCTAssertFalse(product.contains(absent), "\(absent) is the macro's, got:\n\(product)")
        }
        let modules = try funcDefinition("modules_Stringify", in: result)
        XCTAssertFalse(modules.contains("StringifyMacros"), "got:\n\(modules)")
        XCTAssertFalse(modules.contains("SwiftSyntax"), "got:\n\(modules)")
    }

    /// The compiler runs a macro on the Mac that builds, so a package with one asks which
    /// platform is built, as a platform-conditional setting does.
    func test_aPackageWithAMacroAsksForThePlatform() throws {
        let output = try macroConversion(linkerSettings: nil)

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.linkerConfiguration]).keys.sorted(),
                       [SwiftLinkerConfiguration.settingNamespace])
        XCTAssertEqual(try pendingCondition(output),
                       .inputsWithoutValue(kind: .platformSettings, paths: [SwiftLinkerConfiguration.settingNamespace]))
    }

    /// In a build for another platform the macro would have to be built for the Mac beside
    /// it, which is not done; the conversion names the macro, rather than build an
    /// executable for the simulator that the compiler cannot run.
    func test_aMacroInABuildForAnotherPlatformIsTheConversionsError() throws {
        let output = try macroConversion(linkerSettings: "sdk=iphonesimulator")

        XCTAssertEqual(try pendingDocument(output),
                       .engine(.macroForAnotherPlatform(package: "Stringify", target: "StringifyMacros", platform: "ios"),
                               subject: .target(name: "StringifyMacros")))
    }

    /// Settings that hold everywhere need no platform, and the conversion does not ask.
    func test_unconditionalSwiftSettingsNeedNoPlatform() throws {
        let unconditional = swiftSettingsManifest
            .replacingOccurrences(of: #"{"condition": {"platformNames": ["ios"]}, "#, with: "{")
            .replacingOccurrences(of: #"{"condition": {"platformNames": ["macos"]}, "#, with: "{")
        let output = try convert(json: unconditional)
        XCTAssertEqual(output.inputWireSpecs[SwiftFormulaConverter.linkerConfiguration] ?? [:], [:])
        let block = try funcDefinition("compilerModels",
                                       in: try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput]).expectValue().resolveAsString())
        XCTAssertTrue(block.contains("defines: 'SWIFT_PACKAGE,FOO,MAC', "), "got:\n\(block)")
        XCTAssertTrue(block.contains("upcomingFeatures: 'NonisolatedNonsendingByDefault,InferIsolatedConformances'"), "got:\n\(block)")
    }

    /// The literals the converter writes are the ones the compiler reads.
    func test_theCompilerReadsTheSwiftSettingsTheConverterWrites() throws {
        let block = try funcDefinition("compilerModels", in: try formula(json: swiftSettingsManifest,
                                                                         linkerSettings: "sdk=macosx"))
        let literal = try XCTUnwrap(block.range(of: #"SettingsLiteral\([^)]*\)"#, options: .regularExpression).map { String(block[$0]) })
        var properties: [String: String] = ["toolDescriptor.name": "swiftc", "toolDescriptor.version": "test",
                                            "toolDescriptor.platform": "macOS", "toolDescriptor.architecture": "arm64"]
        let pattern = try NSRegularExpression(pattern: #"(\w+): '([^']*)'"#)
        for match in pattern.matches(in: literal, range: NSRange(literal.startIndex..., in: literal)) {
            let key   = String(literal[try XCTUnwrap(Range(match.range(at: 1), in: literal))])
            let value = String(literal[try XCTUnwrap(Range(match.range(at: 2), in: literal))])
            properties[key] = value
        }
        let configuration = try SwiftCompilerConfiguration(properties: properties)

        XCTAssertEqual(configuration.upcomingFeatures, ["NonisolatedNonsendingByDefault"])
        XCTAssertEqual(configuration.experimentalFeatures, ["StrictConcurrency"])
        XCTAssertEqual(configuration.defines, ["SWIFT_PACKAGE", "FOO", "MAC"],
                       "SwiftPM's condition first, which every package target compiles with (B-77)")
        XCTAssertEqual(configuration.packageName, "Models")
        XCTAssertEqual(configuration.unsafeFlags, ["-warnings-as-errors", "-Xcc", "-Wl,-a"])
        XCTAssertEqual(configuration.languageMode, "6")
    }

    // MARK: - Dependencies no target uses

    private func manifest(dependencies: String, targetDependencies: String) -> String {
        """
        {
          "name": "Markdown",
          "dependencies": [\(dependencies)],
          "products": [{"name": "Markdown", "targets": ["Markdown"], "type": {"library": ["automatic"]}}],
          "targets": [
            {"name": "Markdown", "type": "regular", "path": "Sources/Markdown",
             "dependencies": [\(targetDependencies)]},
            {"name": "CAtomic", "type": "regular", "path": "Sources/CAtomic", "dependencies": []}
          ]
        }
        """
    }

    private let cmark = """
        {"sourceControl": [{"identity": "swift-cmark", "location": {"remote": [{"urlString": "https://github.com/swiftlang/swift-cmark.git"}]}}]}
        """
    private let docc = """
        {"sourceControl": [{"identity": "swift-docc-plugin", "location": {"remote": [{"urlString": "https://github.com/apple/swift-docc-plugin"}]}}]}
        """

    /// swift-markdown declares swift-docc-plugin for its documentation build; no target
    /// uses it, SwiftPM never checks it out, and a build waiting for it waited forever.
    func test_doesNotWaitForADependencyNoTargetUses() throws {
        let output = try convert(packageFolder: "input:/repo/Markdown",
                                 json: manifest(dependencies: "\(cmark), \(docc)",
                                                targetDependencies: """
                                                    {"byName": ["CAtomic", null]},
                                                    {"product": ["cmark-gfm", "swift-cmark", null, null]}
                                                    """))

        XCTAssertEqual(try externalSpecs(output).keys.sorted(), ["input:/repo/Markdown/Dependencies/swift-cmark"])
    }

    /// A test target is not built, so what only it depends on — RevenueCat's Nimble — is
    /// not resolved by a consumer either, and waiting for it would wait forever.
    func test_doesNotWaitForADependencyOnlyATestTargetUses() throws {
        let nimble = """
            {"sourceControl": [{"identity": "nimble", "location": {"remote": [{"urlString": "https://github.com/quick/nimble"}]}}]}
            """
        let json = """
            {
              "name": "RC",
              "dependencies": [\(cmark), \(nimble)],
              "products": [{"name": "RC", "targets": ["RC"], "type": {"library": ["automatic"]}}],
              "targets": [
                {"name": "RC", "type": "regular", "path": "Sources/RC",
                 "dependencies": [{"product": ["cmark-gfm", "swift-cmark", null, null]}]},
                {"name": "RCTests", "type": "test", "path": "Tests/RCTests",
                 "dependencies": [{"product": ["Nimble", "nimble", null, null]}, {"byName": ["RC", null]}]}
              ]
            }
            """
        let output = try convert(packageFolder: "input:/repo/RC", json: json)

        XCTAssertEqual(try externalSpecs(output).keys.sorted(), ["input:/repo/RC/Dependencies/swift-cmark"])
    }

    /// A `byName` that names no local target could be a product of any dependency, so
    /// nothing can be dropped: a wait the user can see beats a compile failure that
    /// explains nothing.
    func test_followsEveryDependencyWhenAByNameCouldBeAnyOfTheirProducts() throws {
        let output = try convert(packageFolder: "input:/repo/Markdown",
                                 json: manifest(dependencies: "\(cmark), \(docc)",
                                                targetDependencies: """
                                                    {"byName": ["SomethingExternal", null]}
                                                    """))

        XCTAssertEqual(try externalSpecs(output).keys.sorted(),
                       ["input:/repo/Markdown/Dependencies/swift-cmark",
                        "input:/repo/Markdown/Dependencies/swift-docc-plugin"])
    }

    /// A `byName` naming a dependency — CodeEditSourceEditor's `"CodeEditTextView"`, its
    /// `CodeEditTextView.git` — is that dependency, as SwiftPM's resolution reads it, so the
    /// package's test-only swift-custom-dump, which Xcode never fetches, is not waited for
    /// (B-77). The repository's name matches whatever its case.
    func test_aByNameNamingADependencyWaitsForThatDependencyAlone() throws {
        let textView = """
            {"sourceControl": [{"identity": "codeedittextview", "location": {"remote": [{"urlString": "https://github.com/CodeEditApp/CodeEditTextView.git"}]}}]}
            """
        let customDump = """
            {"sourceControl": [{"identity": "swift-custom-dump", "location": {"remote": [{"urlString": "https://github.com/pointfreeco/swift-custom-dump"}]}}]}
            """
        let json = """
            {
              "name": "CodeEditSourceEditor",
              "dependencies": [\(textView), \(customDump)],
              "products": [{"name": "CodeEditSourceEditor", "targets": ["CodeEditSourceEditor"], "type": {"library": ["automatic"]}}],
              "targets": [
                {"name": "CodeEditSourceEditor", "type": "regular", "path": "Sources/CodeEditSourceEditor",
                 "dependencies": [{"byName": ["CodeEditTextView", null]}]},
                {"name": "CodeEditSourceEditorTests", "type": "test", "path": "Tests/CodeEditSourceEditorTests",
                 "dependencies": [{"byName": ["CodeEditSourceEditor", null]},
                                  {"product": ["CustomDump", "swift-custom-dump", null, null]}]}
              ]
            }
            """
        let output = try convert(packageFolder: "input:/repo/Editor", json: json)

        XCTAssertEqual(try externalSpecs(output).keys.sorted(), ["input:/repo/Editor/Dependencies/CodeEditTextView"])
    }

    /// SQLite.swift's traits as `dump-package` emits them: `SystemSQLite` by default, which
    /// here enables `Shims` in turn, and `SQLCipher` and `SQLiteSwiftCSQLite`, which only a
    /// consumer asking for them enables.
    private let sqliteTraits = """
        [{"name": "SystemSQLite", "enabledTraits": ["Shims"]},
         {"name": "Shims", "enabledTraits": []},
         {"name": "SQLCipher", "enabledTraits": []},
         {"name": "SQLiteSwiftCSQLite", "enabledTraits": []},
         {"name": "default", "enabledTraits": ["SystemSQLite"], "description": "The default traits of this package."}]
        """

    /// SQLite.swift names CSQLite and SQLCipher.swift only behind traits IceCubes never
    /// enables, so SwiftPM never fetches them and `prepare` never vendors them: a package
    /// named only behind a trait the build does not enable is not waited for. One behind a
    /// trait a default trait enables is.
    func test_doesNotWaitForAPackageNamedOnlyBehindATraitTheBuildDoesNotEnable() throws {
        let csqlite = """
            {"sourceControl": [{"identity": "csqlite", "location": {"remote": [{"urlString": "https://github.com/stephencelis/CSQLite"}]},
                                "traits": [{"condition": {"traits": ["FTS5"]}, "name": "FTS5"}]}]}
            """
        let sqlcipher = """
            {"sourceControl": [{"identity": "sqlcipher.swift", "location": {"remote": [{"urlString": "https://github.com/sqlcipher/SQLCipher.swift"}]},
                                "traits": [{"name": "default"}]}]}
            """
        let shims = """
            {"sourceControl": [{"identity": "sqlite-shims", "location": {"remote": [{"urlString": "https://github.com/example/sqlite-shims"}]}}]}
            """
        let json = """
            {
              "name": "SQLite.swift",
              "traits": \(sqliteTraits),
              "dependencies": [\(csqlite), \(sqlcipher), \(shims)],
              "products": [{"name": "SQLite", "targets": ["SQLite"], "type": {"library": ["automatic"]}}],
              "targets": [
                {"name": "SQLite", "type": "regular", "path": "Sources/SQLite",
                 "dependencies": [{"product": ["SQLiteSwiftCSQLite", "CSQLite", null, {"platformNames": [], "traits": ["SQLiteSwiftCSQLite"]}]},
                                  {"product": ["SQLCipher", "SQLCipher.swift", null, {"platformNames": ["ios", "macos"], "traits": ["SQLCipher"]}]},
                                  {"product": ["Shims", "sqlite-shims", null, {"platformNames": [], "traits": ["Shims"]}]}]}
              ]
            }
            """
        let output = try convert(packageFolder: "input:/repo/SQLite", json: json)

        XCTAssertEqual(try externalSpecs(output).keys.sorted(), ["input:/repo/SQLite/Dependencies/sqlite-shims"])
    }

    /// A target dependency or a Swift setting behind a trait the build does not enable is
    /// not one: not wired, not linked, not compiled with — and, though it names platforms,
    /// does not make the conversion ask which platform is built.
    func test_aTargetDependencyBehindATraitTheBuildDoesNotEnableIsNotOne() throws {
        let json = """
            {
              "name": "SQLite.swift",
              "traits": \(sqliteTraits),
              "dependencies": [],
              "products": [{"name": "SQLite", "targets": ["SQLite"], "type": {"library": ["automatic"]}}],
              "targets": [
                {"name": "SQLite", "type": "regular", "path": "Sources/SQLite",
                 "dependencies": [{"target": ["Cipher", {"platformNames": ["ios", "macos"], "traits": ["SQLCipher"]}]},
                                  {"byName": ["System", {"platformNames": [], "traits": ["SQLiteSwiftCSQLite", "SystemSQLite"]}]}],
                 "settings": [{"condition": {"platformNames": [], "traits": ["SQLCipher"]}, "kind": {"define": {"_0": "SQLITE_HAS_CODEC"}}, "tool": "swift"},
                              {"condition": {"platformNames": [], "traits": ["Shims"]}, "kind": {"define": {"_0": "SHIMS"}}, "tool": "swift"},
                              {"condition": {"platformNames": [], "traits": ["SQLCipher"]}, "kind": {"linkedLibrary": {"_0": "sqlcipher"}}, "tool": "linker"}]},
                {"name": "Cipher", "type": "regular", "path": "Sources/Cipher", "dependencies": []},
                {"name": "System", "type": "regular", "path": "Sources/System", "dependencies": []}
              ]
            }
            """
        let output = try convert(json: json)
        XCTAssertEqual(output.inputWireSpecs[SwiftFormulaConverter.linkerConfiguration] ?? [:], [:],
                       "nothing that holds is conditional on a platform")

        let result   = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput]).expectValue().resolveAsString()
        let compiler = try funcDefinition("compilerSQLite", in: result)
        XCTAssertFalse(compiler.contains("Cipher"), "got:\n\(compiler)")
        XCTAssertTrue(compiler.contains("'System': compilerSystem().swiftmodule"),
                      "a trait condition holds when any trait it names is enabled, got:\n\(compiler)")
        XCTAssertTrue(compiler.contains("defines: 'SWIFT_PACKAGE,SHIMS', "), "got:\n\(compiler)")
        XCTAssertFalse(result.contains("sqlcipher"), "got:\n\(result)")
    }

    /// `.package(name: "Models", path: ...)` is referenced as "Models" while its identity
    /// is "models": the match is case-insensitive.
    func test_matchesAPathDependencysIdentityCaseInsensitively() throws {
        let output = try convert(packageFolder: "input:/repo/App", json: """
            {
              "name": "App",
              "dependencies": [{"fileSystem": [{"identity": "models", "path": "../Models"}]},
                               {"fileSystem": [{"identity": "unused", "path": "../Unused"}]}],
              "products": [{"name": "App", "targets": ["App"], "type": {"executable": null}}],
              "targets": [{"name": "App", "type": "executable", "path": "App",
                           "dependencies": [{"product": ["Models", "Models", null, null]}]}]
            }
            """)

        XCTAssertEqual(try externalSpecs(output).keys.sorted(), ["input:/repo/Models"])
    }

    // MARK: - C targets (B-54)

    // swift-cmark, reached through EmojiText and swift-markdown, is 34 C files in two
    // targets whose headers live in `include/` beside a module map. A manifest says
    // nothing about a target's language; its folder does. A C target is built through the
    // clang nodes the way the hand-written C formulas write them, its objects link beside
    // the Swift ones, and its public headers reach Swift the way a system library's do.

    private func file(_ name: String)   -> FolderManifestEntry { .init(name: name, isFolder: false, isPinned: true) }
    private func folder(_ name: String) -> FolderManifestEntry { .init(name: name, isFolder: true,  isPinned: true) }

    private let appOverCLib = """
        {
          "name": "App",
          "dependencies": [],
          "products": [{"name": "App", "targets": ["App"], "type": {"executable": null}}],
          "targets": [
            {"name": "App",  "type": "executable", "path": "Sources/App", "dependencies": [{"byName": ["CLib", null]}]},
            {"name": "CLib", "type": "regular",    "path": "src",         "dependencies": []},
            {"name": "CExt", "type": "regular",    "path": "extensions",  "dependencies": [{"byName": ["CLib", null]}]}
          ]
        }
        """

    private var cFolders: [String: [FolderManifestEntry]] {
        ["input:/pkg/src":        [file("blocks.c"), file("parser.h"), file("CMakeLists.txt"), folder("include")],
         "input:/pkg/extensions": [file("table.c"), folder("include")]]
    }

    func test_waitsForEveryCompilableTargetsFolderBeforeGenerating() throws {
        let output = try convert(json: appOverCLib, supplyTargetFolders: false)

        XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.targetFolders]).rendered,
                       ["input:/pkg/Sources/App": "Folder(path: 'input:/pkg/Sources/App').subtreeManifest",
                        "input:/pkg/src":         "Folder(path: 'input:/pkg/src').subtreeManifest",
                        "input:/pkg/extensions":  "Folder(path: 'input:/pkg/extensions').subtreeManifest"])
        XCTAssertEqual(try pendingCondition(output),
                       .inputsWithoutValue(kind: .targetFolders,
                                           paths: ["input:/pkg/Sources/App", "input:/pkg/extensions", "input:/pkg/src"]))
    }

    /// The passes a conversion takes, from a converter with nothing wired, answering each
    /// pass's demands as the engine would, until one publishes a formula: the package's
    /// folder and manifest, then every target's tree (B-135).
    private func passesToConvert(json: String, listings: [String: [FolderManifestEntry]]) throws -> (passes: Int, formula: String) {
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind, name: nil,
                                                                       properties: ["path": "input:/pkg"], scheduled: false, identity: nil))
        var inputValues: [String: [String: NodeValue]] = [:]
        for pass in 1...8 {
            let output = try converter.process(input: ProcessInput(inputValues: inputValues))
            if case .value(let hash)? = output.outputValues[SwiftFormulaConverter.formulaOutput] {
                return (pass, try hash.resolveAsString())
            }
            for (port, specs) in output.inputWireSpecs {
                for (key, spec) in specs where inputValues[port]?[key] == nil {
                    switch spec.outputPort {
                    case FileSystemNodes.folderManifestPort:
                        inputValues[port, default: [:]][key] =
                            .value(try FolderManifest(baseFolderPath: key, entries: listings[key] ?? []).toJSON().intern())
                    case FileSystemNodes.folderSubtreeManifestPort:
                        inputValues[port, default: [:]][key] =
                            .value(try FolderSubtreeManifest.folding(at: key, listings: listings).toJSON().intern())
                    default:
                        // The package's manifest, read by its reader.
                        inputValues[port, default: [:]][key] = .value(try json.intern())
                    }
                }
            }
        }
        XCTFail("no formula after eight passes")
        return (0, "")
    }

    /// A target whose resources are three folders down is converted in the passes the
    /// package's folder and manifest and the target's tree need — three, however deep the
    /// target goes — where a walk over manifests took a pass per level (B-135).
    func test_aTargetThreeFoldersDeepIsConvertedInThePassesItsTreeNeedsNotOnePerLevel() throws {
        let json = """
            {"name": "pkg", "dependencies": [],
             "products": [{"name": "pkg", "targets": ["Lib"], "type": {"library": ["automatic"]}}],
             "targets": [{"name": "Lib", "type": "regular", "path": "Sources/Lib", "dependencies": [], "resources": []}]}
            """
        let shallow = ["input:/pkg/Sources/Lib": [file("Lib.swift"), folder("en.lproj")],
                       "input:/pkg/Sources/Lib/en.lproj": [file("Localizable.strings")]]
        let deep = ["input:/pkg/Sources/Lib":          [file("Lib.swift"), folder("A")],
                    "input:/pkg/Sources/Lib/A":        [folder("B")],
                    "input:/pkg/Sources/Lib/A/B":      [folder("C")],
                    "input:/pkg/Sources/Lib/A/B/C":    [folder("en.lproj")],
                    "input:/pkg/Sources/Lib/A/B/C/en.lproj": [file("Localizable.strings")]]

        let shallowConversion = try passesToConvert(json: json, listings: shallow)
        let deepConversion    = try passesToConvert(json: json, listings: deep)

        XCTAssertEqual(shallowConversion.passes, 3, "the package's folder and manifest, then the target's tree, then the formula")
        XCTAssertEqual(deepConversion.passes, shallowConversion.passes, "three folders down costs no pass more")
        XCTAssertTrue(deepConversion.formula.contains("Folder(path: 'input:/pkg/Sources/Lib/A/B/C/en.lproj').manifest"),
                      deepConversion.formula)
    }

    func test_aTargetWhoseFolderHoldsCSourcesIsBuiltThroughTheClangNodes() throws {
        let result = try formula(json: appOverCLib, folderContents: cFolders)

        XCTAssertFalse(result.contains("func compilerCLib"), "a C target has no Swift compiler, got:\n\(result)")
        let preprocessor = try XCTUnwrap(result.components(separatedBy: "\n\n").first { $0.hasPrefix("func preprocessCLib(path)") },
                                         "got:\n\(result)")
        XCTAssertTrue(preprocessor.contains("ClangPreprocessor("), "got:\n\(preprocessor)")
        XCTAssertTrue(preprocessor.contains("ConfigFilter(prefix: 'clang.preprocessor'"), "got:\n\(preprocessor)")
        XCTAssertTrue(preprocessor.contains("'input:/pkg/src': Folder(path: 'input:/pkg/src').manifest"), "got:\n\(preprocessor)")
        XCTAssertTrue(preprocessor.contains("'input:/pkg/src/include': Folder(path: 'input:/pkg/src/include').manifest"), "got:\n\(preprocessor)")

        let product = try productBlock("App", in: result)
        XCTAssertTrue(product.contains("{f: 'input:/pkg/src/**/*.c'} \"%%f%%.o\": ClangCompiler("), "got:\n\(product)")
        XCTAssertTrue(product.contains("preprocessCLib(path: f)"), "got:\n\(product)")
        XCTAssertTrue(product.contains("ConfigFilter(prefix: 'clang.compiler'"), "got:\n\(product)")
        XCTAssertTrue(product.contains("'App.o': compilerApp().object"), "the Swift objects still link, got:\n\(product)")
    }

    /// `prepare` writes a config block for each namespace the converter declares and no
    /// other, so the declaration has to cover every prefix the formula selects — for a
    /// package with C targets, and for this repository's own root. The package reader's
    /// filter is not in the formula text: the converter wires it itself, and
    /// `test_theExternalPackageReaderIsWiredToASelectorForItsOwnNamespace` covers that one.
    func test_theDeclaredConfigNamespacesCoverEveryPrefixTheFormulaSelects() throws {
        let selected = try configFilterPrefixes(in: formula(json: appOverCLib, folderContents: cFolders))
            .union(configFilterPrefixes(in: rootFormula()))

        XCTAssertTrue(selected.isSuperset(of: ["swift.compiler", "swift.linker", "clang.preprocessor", "clang.compiler"]),
                      "\(selected.sorted())")
        XCTAssertTrue(selected.isSubset(of: SwiftFormulaConverter.configNamespaces),
                      "selected \(selected.sorted()), declared \(SwiftFormulaConverter.configNamespaces)")
    }

    private func configFilterPrefixes(in formula: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: "ConfigFilter\\(prefix: '([^']+)'")
        let matches = pattern.matches(in: formula, range: NSRange(formula.startIndex..., in: formula))
        return Set(matches.compactMap { Range($0.range(at: 1), in: formula).map { String(formula[$0]) } })
    }

    func test_aSwiftTargetDependingOnACTargetGetsItsHeaderTree() throws {
        let result = try formula(json: appOverCLib, folderContents: cFolders)

        let block = try funcDefinition("compilerApp", in: result)
        XCTAssertTrue(block.contains("moduleTrees: [\n            'CLib': headersCLib().files\n    ]"), "got:\n\(block)")
        XCTAssertFalse(block.contains("inputModuleMapFolders"), "got:\n\(block)")
        XCTAssertFalse(block.contains("compilerCLib().swiftmodule"), "a C target has no swiftmodule, got:\n\(block)")
        // The product's module tree carries the same value, so an app and a target beside
        // the C one in its package import one module.
        XCTAssertTrue(try funcDefinition("modules_App", in: result).contains("'CLib': headersCLib().files"), "got:\n\(result)")
        // Defined before the compiler that names it.
        let headersAt  = try XCTUnwrap(result.range(of: "func headersCLib()")).lowerBound
        let compilerAt = try XCTUnwrap(result.range(of: "func compilerApp()")).lowerBound
        XCTAssertLessThan(headersAt, compilerAt)
    }

    /// The tree holds the headers of the whole target at their paths in it, under the
    /// target's name, not the public folder's alone: a public header may reach back into
    /// the target, as NetNewsWire's `include/RSDatabaseObjC.h` does with
    /// `#import "../FMDatabase.h"`. Sources are not headers and stay out.
    func test_aCTargetsHeaderTreeHoldsEveryHeaderOfTheTargetAtItsPath() throws {
        var tree = cFolders
        tree["input:/pkg/src/include"] = [file("CLib.h")]
        let headers = try funcDefinition("headersCLib", in: formula(json: appOverCLib, folderContents: tree))

        XCTAssertTrue(headers.contains("'CLib/parser.h': StaticFile(path: 'input:/pkg/src/parser.h').output"), "got:\n\(headers)")
        XCTAssertTrue(headers.contains("'CLib/include/CLib.h': StaticFile(path: 'input:/pkg/src/include/CLib.h').output"),
                      "got:\n\(headers)")
        XCTAssertFalse(headers.contains("blocks.c"), "got:\n\(headers)")
        XCTAssertFalse(headers.contains("CMakeLists"), "got:\n\(headers)")
    }

    // MARK: - The module map SwiftPM writes (B-55)

    // A C target whose public-headers folder has no `module.modulemap` is importable from
    // Swift all the same: SwiftPM writes one. PLCrashReporter's `import CrashReporter` and
    // Zip's `import Minizip` rest on it.

    func test_anUmbrellaHeaderNamedForTheModuleGetsAModuleMapBesideIt() throws {
        var tree = cFolders
        tree["input:/pkg/src/include"] = [file("CLib.h"), file("detail.h")]
        let headers = try funcDefinition("headersCLib", in: formula(json: appOverCLib, folderContents: tree))

        XCTAssertTrue(headers.contains("'CLib/include/module.modulemap': ModuleMapWriter(moduleName: 'CLib', umbrellaHeader: 'CLib.h').output"),
                      "got:\n\(headers)")
    }

    func test_aPublicFolderWithNoUmbrellaHeaderIsAnUmbrellaDirectory() throws {
        var tree = cFolders
        tree["input:/pkg/src/include"] = [file("parser.h"), file("render.h")]
        let headers = try funcDefinition("headersCLib", in: formula(json: appOverCLib, folderContents: tree))

        XCTAssertTrue(headers.contains("'CLib/include/module.modulemap': ModuleMapWriter(moduleName: 'CLib', umbrellaDirectory: '.').output"),
                      "got:\n\(headers)")
    }

    /// A module map of the target's own is used as it is, and none is written.
    func test_aPublicFolderWithItsOwnModuleMapGetsNoneWritten() throws {
        var tree = cFolders
        tree["input:/pkg/src/include"] = [file("CLib.h"), file("module.modulemap")]
        let headers = try funcDefinition("headersCLib", in: formula(json: appOverCLib, folderContents: tree))

        XCTAssertTrue(headers.contains("'CLib/include/module.modulemap': StaticFile(path: 'input:/pkg/src/include/module.modulemap').output"),
                      "got:\n\(headers)")
        XCTAssertFalse(headers.contains("ModuleMapWriter"), "got:\n\(headers)")
    }

    /// SwiftPM's rule, case by case, over the public folder's listing.
    func test_theModuleMapFollowsSwiftPMsRule() {
        func manifest(_ path: String, _ entries: [FolderManifestEntry]) -> (String, FolderManifest) {
            (path, FolderManifest(baseFolderPath: path, entries: entries))
        }
        func moduleMap(_ listings: [(String, FolderManifest)]) -> PackageClangTarget.ModuleMap? {
            PackageClangTarget.moduleMap(moduleName: "Kit", publicHeadersFolder: "input:/include",
                                         manifests: Dictionary(uniqueKeysWithValues: listings))
        }

        XCTAssertEqual(moduleMap([manifest("input:/include", [file("Kit.h"), file("module.modulemap")])]), .provided)
        XCTAssertEqual(moduleMap([manifest("input:/include", [file("Kit.h"), file("Other.h")])]), .umbrellaHeader("Kit.h"))
        XCTAssertEqual(moduleMap([manifest("input:/include", [folder("Kit")]),
                                  manifest("input:/include/Kit", [file("Kit.h"), file("Part.h")])]),
                       .umbrellaHeader("Kit/Kit.h"))
        XCTAssertEqual(moduleMap([manifest("input:/include", [file("a.h"), folder("sub")])]), .umbrellaDirectory)
        XCTAssertEqual(moduleMap([manifest("input:/include", [])]), .umbrellaDirectory)
        // SwiftPM refuses these, and so the target has no module.
        XCTAssertNil(moduleMap([manifest("input:/include", [file("Kit.h"), folder("sub")])]))
        XCTAssertNil(moduleMap([manifest("input:/include", [folder("Kit"), file("stray.h")]),
                                manifest("input:/include/Kit", [file("Kit.h")])]))
    }

    /// Zip, as NetNewsWire pins it: the C target `Minizip` sits at `Zip/minizip`, inside the
    /// folder of the Swift target `Zip` that excludes it and imports it. Its public folder
    /// has `Minizip.h` and no module map; the one at `minizip/module` is excluded, and must
    /// stay out of the tree, where it would declare `Minizip` a second time on the import path.
    func test_aCTargetNestedInItsSwiftTargetsFolderReachesItAsAnyDependencyDoes() throws {
        let json = """
            {
              "name": "Zip",
              "dependencies": [],
              "products": [{"name": "Zip", "targets": ["Zip"], "type": {"library": ["automatic"]}}],
              "targets": [
                {"name": "Minizip", "type": "regular", "path": "Zip/minizip", "dependencies": [], "exclude": ["module"]},
                {"name": "Zip", "type": "regular", "path": "Zip", "dependencies": [{"byName": ["Minizip", null]}],
                 "exclude": ["minizip", "zlib"]}
              ]
            }
            """
        let tree: [String: [FolderManifestEntry]] = [
            "input:/pkg/Zip":                 [file("Zip.swift"), file("Zip.h"), folder("minizip"), folder("zlib")],
            "input:/pkg/Zip/zlib":            [file("module.modulemap")],
            "input:/pkg/Zip/minizip":         [file("zip.c"), file("unzip.c"), folder("include"), folder("module")],
            "input:/pkg/Zip/minizip/include": [file("Minizip.h"), file("zip.h"), file("unzip.h")],
            "input:/pkg/Zip/minizip/module":  [file("module.modulemap")],
        ]
        let result = try formula(json: json, folderContents: tree)

        let compiler = try funcDefinition("compilerZip", in: result)
        XCTAssertTrue(compiler.contains("'Minizip': headersMinizip().files"), "got:\n\(compiler)")
        let headers = try funcDefinition("headersMinizip", in: result)
        XCTAssertTrue(headers.contains("'Minizip/include/module.modulemap': ModuleMapWriter(moduleName: 'Minizip', umbrellaHeader: 'Minizip.h')"),
                      "got:\n\(headers)")
        XCTAssertTrue(headers.contains("'Minizip/include/zip.h'"), "got:\n\(headers)")
        XCTAssertFalse(headers.contains("minizip/module"), "an excluded module map, got:\n\(headers)")
        let product = try productBlock("libZip.a", in: result)
        XCTAssertTrue(product.contains("{f: 'input:/pkg/Zip/minizip/**/*.c'}"), "got:\n\(product)")
    }

    // MARK: - Objective-C (B-77)

    /// NetNewsWire's `RSDatabaseObjC` (FMDB): Objective-C whose headers open with
    /// `@import Foundation;` and whose code assumes ARC. SwiftPM builds it with modules and
    /// ARC, and the converter says so to both clang stages, as literals.
    func test_aCTargetWithObjectiveCIsPreprocessedAndCompiledWithModulesAndARC() throws {
        var tree = cFolders
        tree["input:/pkg/src"] = [file("FMDatabase.m"), file("FMDatabase.h"), folder("include")]
        tree["input:/pkg/src/include"] = [file("CLib.h")]
        let result = try formula(json: appOverCLib, folderContents: tree)

        let preprocessor = try XCTUnwrap(result.components(separatedBy: "\n\n").first { $0.hasPrefix("func preprocessCLib(path)") })
        XCTAssertTrue(preprocessor.contains("SettingsLiteral(defines: 'SWIFT_PACKAGE=1', moduleName: 'CLib', modules: 'true', objectiveCARC: 'true')"),
                      "got:\n\(preprocessor)")
        let compilerEntry = try XCTUnwrap(try productBlock("App", in: result).components(separatedBy: "\n")
                                              .first { $0.contains("preprocessCLib") })
        XCTAssertTrue(compilerEntry.contains("SettingsLiteral(modules: 'true', objectiveCARC: 'true')"), "got:\n\(compilerEntry)")
    }

    /// A plain C target is left as it was: SwiftPM would enable modules for it too, but its
    /// preprocessed text would then import its dependencies' modules, which the compiler
    /// has no module map for.
    func test_aPlainCTargetTakesNeitherModulesNorARC() throws {
        let result = try formula(json: appOverCLib, folderContents: cFolders)

        XCTAssertFalse(result.contains("objectiveCARC"), "got:\n\(result)")
        XCTAssertFalse(result.contains("modules: 'true'"), "got:\n\(result)")
    }

    /// cmark-gfm-extensions includes cmark-gfm's headers by search path; SwiftPM puts the
    /// dependency's public headers on it, and so does the generated preprocessor.
    func test_aCTargetsHeaderFoldersIncludeThePublicHeadersOfTheCTargetsItDependsOn() throws {
        let json = appOverCLib.replacingOccurrences(of: "[{\"byName\": [\"CLib\", null]}]},\n    {\"name\": \"CLib\"",
                                                   with: "[{\"byName\": [\"CExt\", null]}]},\n    {\"name\": \"CLib\"")
        let result = try formula(json: json, folderContents: cFolders)

        let preprocessor = try XCTUnwrap(result.components(separatedBy: "\n\n").first { $0.hasPrefix("func preprocessCExt(path)") },
                                         "got:\n\(result)")
        XCTAssertTrue(preprocessor.contains("'input:/pkg/extensions': Folder"), "its own folder, got:\n\(preprocessor)")
        XCTAssertTrue(preprocessor.contains("'input:/pkg/src/include': Folder"), "its dependency's public headers, got:\n\(preprocessor)")
        XCTAssertFalse(preprocessor.contains("'input:/pkg/src': Folder"), "not its dependency's private folder, got:\n\(preprocessor)")

        let product = try productBlock("App", in: result)
        XCTAssertTrue(product.contains("{f: 'input:/pkg/src/**/*.c'}"), "objects of a C target reached through a C target, got:\n\(product)")
        XCTAssertTrue(product.contains("{f: 'input:/pkg/extensions/**/*.c'}"), "got:\n\(product)")
    }

    /// A Swift target whose sources all sit in subfolders has no `.swift` at the top of
    /// its folder — and no C source either, so it stays Swift.
    func test_aTargetWithSourcesOnlyInSubfoldersStaysSwift() throws {
        let result = try formula(json: appOverCLib,
                                 folderContents: ["input:/pkg/Sources/App": [folder("Base"), folder("Views")]]
                                     .merging(cFolders) { _, new in new })

        XCTAssertTrue(result.contains("func compilerApp()"), "got:\n\(result)")
    }

    // MARK: - C targets: what the first case did not need (B-55)

    /// The whole tree decides, as it does for SwiftPM: a `.swift` anywhere makes a Swift
    /// target, even beside a stray `.c` at the top.
    func test_aSwiftFileInASubfolderMakesASwiftTargetDespiteATopLevelCSource() throws {
        let result = try formula(json: appOverCLib,
                                 folderContents: ["input:/pkg/Sources/App":       [file("shim.c"), folder("Views")],
                                                  "input:/pkg/Sources/App/Views": [file("Main.swift")]]
                                     .merging(cFolders) { _, new in new })

        XCTAssertTrue(result.contains("func compilerApp()"), "got:\n\(result)")
        XCTAssertFalse(result.contains("func preprocessApp("), "got:\n\(result)")
    }

    /// A C target whose sources all sit in subfolders is a C target, every extension its
    /// tree holds taken at any depth by one for-each.
    func test_aCTargetsSourcesAreTakenAtAnyDepthForEveryExtensionItsTreeHolds() throws {
        let result = try formula(json: appOverCLib,
                                 folderContents: ["input:/pkg/src":          [folder("include"), folder("core")],
                                                  "input:/pkg/src/core":     [file("parser.c"), folder("deep")],
                                                  "input:/pkg/src/core/deep": [file("table.cpp"), file("table.h")]]
                                     .merging(["input:/pkg/extensions": [file("table.c")]]) { _, new in new })

        let product = try productBlock("App", in: result)
        XCTAssertTrue(product.contains("{f: 'input:/pkg/src/**/*.c', 'input:/pkg/src/**/*.cpp'} \"%%f%%.o\": ClangCompiler("),
                      "got:\n\(product)")
        XCTAssertFalse(result.contains("func compilerCLib"), "got:\n\(result)")
    }

    private func cLibJSON(_ fields: String) -> String {
        appOverCLib.replacingOccurrences(of: "{\"name\": \"CLib\", \"type\": \"regular\",    \"path\": \"src\",         \"dependencies\": []}",
                                         with: "{\"name\": \"CLib\", \"type\": \"regular\", \"path\": \"src\", \"dependencies\": [], \(fields)}")
    }

    private var cLibTree: [String: [FolderManifestEntry]] {
        ["input:/pkg/src":            [file("blocks.c"), file("skip.c"), file("scanners.re"), file("CMakeLists.txt"),
                                       folder("include"), folder("Tests"), folder("docs"), folder("lib")],
         "input:/pkg/src/Tests":      [file("test.c")],
         "input:/pkg/src/docs":       [file("index.md")],
         "input:/pkg/src/lib":        [file("util.c"), file("util.h")],
         "input:/pkg/extensions":     [file("table.c")]]
    }

    /// `exclude:` is the for-each's `except`, relative to the target folder as the
    /// manifest writes it: a folder as everything under it, a file as itself. An exclusion
    /// that takes out no source the patterns would take is left out of the formula.
    func test_aCTargetsExclusionsAreTheForEachsExcept() throws {
        let json = cLibJSON("\"exclude\": [\"skip.c\", \"Tests\", \"docs\", \"CMakeLists.txt\", \"scanners.re\"]")
        let result = try formula(json: json, folderContents: cLibTree)

        let product = try productBlock("App", in: result)
        XCTAssertTrue(product.contains("{f: 'input:/pkg/src/**/*.c' except 'input:/pkg/src/Tests/**', 'input:/pkg/src/skip.c'} "),
                      "got:\n\(product)")
    }

    /// Without an `exclude:`, no `except`.
    func test_aCTargetWithNoExclusionsHasNoExcept() throws {
        let result = try formula(json: appOverCLib, folderContents: cLibTree)

        XCTAssertFalse(try productBlock("App", in: result).contains(" except "), "got:\n\(result)")
    }

    /// `sources:` narrows the for-each: a listed folder is taken at any depth, a listed
    /// file by name, and nothing outside them.
    func test_aCTargetsSourcesListNarrowsTheForEach() throws {
        let json = cLibJSON("\"sources\": [\"lib\", \"blocks.c\"]")
        let result = try formula(json: json, folderContents: cLibTree)

        let product = try productBlock("App", in: result)
        XCTAssertTrue(product.contains("{f: 'input:/pkg/src/blocks.c', 'input:/pkg/src/lib/**/*.c'} "), "got:\n\(product)")
    }

    /// `publicHeadersPath` names the folder the module map is in, for a Swift importer and
    /// for the C target's own preprocessor; `include` is only its default.
    func test_aCTargetsPublicHeadersPathIsItsHeaderFolder() throws {
        let json = cLibJSON("\"publicHeadersPath\": \"api/public\"")
        var tree = cLibTree
        tree["input:/pkg/src"]?.append(folder("api"))
        tree["input:/pkg/src/api"] = [folder("public")]
        tree["input:/pkg/src/api/public"] = [file("module.modulemap"), file("clib.h")]
        let result = try formula(json: json, folderContents: tree)

        let headers = try funcDefinition("headersCLib", in: result)
        XCTAssertTrue(headers.contains("'CLib/api/public/module.modulemap': StaticFile(path: 'input:/pkg/src/api/public/module.modulemap')"),
                      "the named folder's module map, got:\n\(headers)")
        XCTAssertTrue(headers.contains("'CLib/api/public/clib.h'"), "got:\n\(headers)")
        let preprocessor = try XCTUnwrap(result.components(separatedBy: "\n\n").first { $0.hasPrefix("func preprocessCLib(path)") })
        XCTAssertTrue(preprocessor.contains("'input:/pkg/src/api/public': Folder"), "got:\n\(preprocessor)")
        XCTAssertFalse(preprocessor.contains("'input:/pkg/src/include': Folder"), "not the default once one is named, got:\n\(preprocessor)")
    }

    /// A named public folder with an umbrella header and no module map gets the map there,
    /// not in `include`.
    func test_aPublicHeadersPathWithAnUmbrellaHeaderGetsItsModuleMapThere() throws {
        let json = cLibJSON("\"publicHeadersPath\": \"api/public\"")
        var tree = cLibTree
        tree["input:/pkg/src"]?.append(folder("api"))
        tree["input:/pkg/src/api"] = [folder("public")]
        tree["input:/pkg/src/api/public"] = [file("CLib.h"), file("shapes.h")]
        let headers = try funcDefinition("headersCLib", in: formula(json: json, folderContents: tree))

        XCTAssertTrue(headers.contains("'CLib/api/public/module.modulemap': ModuleMapWriter(moduleName: 'CLib', umbrellaHeader: 'CLib.h')"),
                      "got:\n\(headers)")
    }

    /// `publicHeadersPath: "."` is the target folder itself, which is then one header
    /// folder, not two.
    func test_aPublicHeadersPathOfDotIsTheTargetFolder() throws {
        let result = try formula(json: cLibJSON("\"publicHeadersPath\": \".\""), folderContents: cLibTree)

        XCTAssertTrue(try funcDefinition("headersCLib", in: result)
                        .contains("'CLib/module.modulemap': ModuleMapWriter(moduleName: 'CLib', umbrellaDirectory: '.')"),
                      "the map in the target folder itself, got:\n\(result)")
        let preprocessor = try XCTUnwrap(result.components(separatedBy: "\n\n").first { $0.hasPrefix("func preprocessCLib(path)") })
        XCTAssertEqual(preprocessor.components(separatedBy: "'input:/pkg/src': Folder").count, 2, "once, got:\n\(preprocessor)")
    }

    private let defineSettings = """
        "settings": [
          {"kind": {"define": {"_0": "FOO"}}, "tool": "c"},
          {"kind": {"define": {"_0": "BAR=2"}}, "tool": "c"},
          {"condition": {"platformNames": ["windows"]}, "kind": {"define": {"_0": "WIN"}}, "tool": "c"},
          {"kind": {"headerSearchPath": {"_0": "lib"}}, "tool": "c"},
          {"kind": {"define": {"_0": "CXXONLY=yes"}}, "tool": "cxx"}
        ]
        """

    /// Unconditional `.define` settings, from `cSettings` and `cxxSettings` alike, are the
    /// preprocessor's `defines`, laid over the config as a literal; a conditional one is
    /// not carried, and the compiler, reading preprocessed text, has none.
    func test_aCTargetsUnconditionalDefinesAreThePreprocessorsDefines() throws {
        let result = try formula(json: cLibJSON(defineSettings), folderContents: cLibTree)

        let preprocessor = try XCTUnwrap(result.components(separatedBy: "\n\n").first { $0.hasPrefix("func preprocessCLib(path)") })
        XCTAssertTrue(preprocessor.contains("SettingsLiteral(defines: 'SWIFT_PACKAGE=1,FOO,BAR=2,CXXONLY=yes')"), "got:\n\(preprocessor)")
        XCTAssertFalse(preprocessor.contains("WIN"), "a conditional define is not carried, got:\n\(preprocessor)")
        let compilerEntry = try XCTUnwrap(try productBlock("App", in: result).components(separatedBy: "\n").first { $0.contains("preprocessCLib") })
        XCTAssertFalse(compilerEntry.contains("defines"), "got:\n\(compilerEntry)")
    }

    /// A package vending an executable whose targets are all C links it through the Swift
    /// linker, as it links a Swift executable's C objects: `swiftc` drives `ld` for C
    /// objects as well, so there is no `clang.linker` block to read.
    func test_anExecutableOfCTargetsAloneLinksTheirObjectsThroughTheSwiftLinker() throws {
        let json = """
            {
              "name": "Tool",
              "dependencies": [],
              "products": [{"name": "tool", "targets": ["CMain"], "type": {"executable": null}}],
              "targets": [
                {"name": "CMain", "type": "executable", "path": "main", "dependencies": [{"byName": ["CLib", null]}]},
                {"name": "CLib",  "type": "regular",    "path": "src",  "dependencies": []}
              ]
            }
            """
        let result = try formula(json: json, folderContents: ["input:/pkg/main": [file("main.c")],
                                                              "input:/pkg/src":  [file("blocks.c"), folder("include")]])

        XCTAssertFalse(result.contains("SwiftCompiler("), "no Swift to compile, got:\n\(result)")
        XCTAssertFalse(result.contains("ClangLinker"), "got:\n\(result)")
        let product = try productBlock("tool", in: result)
        XCTAssertTrue(product.contains("SwiftLinker("), "got:\n\(product)")
        XCTAssertTrue(product.contains("linkage: 'executable'"), "got:\n\(product)")
        XCTAssertTrue(product.contains("{f: 'input:/pkg/main/**/*.c'}"), "got:\n\(product)")
        XCTAssertTrue(product.contains("{f: 'input:/pkg/src/**/*.c'}"), "got:\n\(product)")
    }

    /// `.headerSearchPath` is one more header folder for the target's own preprocessor, at
    /// its path under the target; one naming no folder is left out, as clang passes over a
    /// search path that is not there.
    func test_aCTargetsHeaderSearchPathsAreHeaderFoldersOfItsPreprocessor() throws {
        let settings = """
            "settings": [
              {"kind": {"headerSearchPath": {"_0": "lib"}}, "tool": "c"},
              {"kind": {"headerSearchPath": {"_0": "./lib/"}}, "tool": "cxx"},
              {"kind": {"headerSearchPath": {"_0": "missing"}}, "tool": "c"},
              {"condition": {"platformNames": ["windows"]}, "kind": {"headerSearchPath": {"_0": "docs"}}, "tool": "c"}
            ]
            """
        let result = try formula(json: cLibJSON(settings), folderContents: cLibTree)

        let preprocessor = try XCTUnwrap(result.components(separatedBy: "\n\n").first { $0.hasPrefix("func preprocessCLib(path)") })
        XCTAssertEqual(preprocessor.components(separatedBy: "'input:/pkg/src/lib': Folder(path: 'input:/pkg/src/lib').manifest").count, 2,
                       "once, however it is spelled, got:\n\(preprocessor)")
        XCTAssertFalse(preprocessor.contains("missing"), "got:\n\(preprocessor)")
        XCTAssertFalse(preprocessor.contains("docs"), "a conditional search path is not carried, got:\n\(preprocessor)")
    }

    // MARK: - A target at its package's root (B-134)

    /// PLCrashReporter as NetNewsWire pins it (1.12.2): one C and Objective-C target at the
    /// package root, `path: ""`, its sources two folders a `sources:` list names, a header
    /// folder by `.headerSearchPath`, a define with an empty value, and a processed privacy
    /// manifest outside the sources.
    private let crashReporterManifest = """
        {
          "name": "PLCrashReporter",
          "dependencies": [],
          "products": [{"name": "CrashReporter", "targets": ["CrashReporter"], "type": {"library": ["automatic"]}}],
          "targets": [
            {"name": "CrashReporter", "type": "regular", "path": "", "dependencies": [],
             "sources": ["Source", "Dependencies/protobuf-c"],
             "exclude": ["Source/dwarf_stack.hpp", "Tools/CrashViewer/", "Dependencies/protobuf-c/generate-pb-c.sh"],
             "resources": [{"path": "Resources/PrivacyInfo.xcprivacy", "rule": {"process": {}}}],
             "settings": [
               {"kind": {"define": {"_0": "PLCR_PRIVATE"}}, "tool": "c"},
               {"kind": {"define": {"_0": "PLCRASHREPORTER_PREFIX="}}, "tool": "c"},
               {"kind": {"headerSearchPath": {"_0": "Dependencies/protobuf-c"}}, "tool": "c"},
               {"kind": {"linkedFramework": {"_0": "Foundation"}}, "tool": "linker"}
             ]}
          ]
        }
        """

    private var crashReporterTree: [String: [FolderManifestEntry]] {
        ["input:/pkg":                              [file("Package.swift"), folder("Source"), folder("Dependencies"),
                                                     folder("include"), folder("Resources"), folder("Tests"), folder("Tools")],
         "input:/pkg/Source":                       [file("CrashReporter.m"), file("PLCrashAsync.c"), file("PLCrashAsyncDwarfCIE.cpp"),
                                                     file("PLCrashSignalHandler.mm"), file("dwarf_stack.hpp"), file("PLCrashReport.pb-c.h")],
         "input:/pkg/Dependencies":                 [folder("protobuf-c")],
         "input:/pkg/Dependencies/protobuf-c":      [folder("protobuf-c"), file("generate-pb-c.sh")],
         "input:/pkg/Dependencies/protobuf-c/protobuf-c": [file("protobuf-c.c"), file("protobuf-c.h")],
         "input:/pkg/include":                      [file("CrashReporter.h")],
         "input:/pkg/Resources":                    [file("PrivacyInfo.xcprivacy"), file("Info.plist")],
         "input:/pkg/Tests":                        [file("CrashReporterTests.m"), file("SwiftTests.swift")],
         "input:/pkg/Tools":                        [folder("CrashViewer")],
         "input:/pkg/Tools/CrashViewer":            [file("main.m")]]
    }

    /// The target's folder is the package folder itself, by the name every other demand
    /// for it uses: spelled `input:/pkg/`, it was a second node for one folder's name.
    func test_aTargetAtThePackageRootDemandsThePackageFolderItself() throws {
        for spelling in ["", ".", "./"] {
            let json = crashReporterManifest.replacingOccurrences(of: "\"path\": \"\"", with: "\"path\": \"\(spelling)\"")
            let output = try convert(json: json, supplyTargetFolders: false)

            XCTAssertEqual(try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.targetFolders]).rendered,
                           ["input:/pkg": "Folder(path: 'input:/pkg').subtreeManifest"], "path: \"\(spelling)\"")
        }
    }

    /// A target path ending in `/` is the folder without it.
    func test_aTargetPathWithATrailingSlashDemandsTheFolderWithoutIt() throws {
        let json = cLibJSON("\"exclude\": []").replacingOccurrences(of: "\"path\": \"src\"", with: "\"path\": \"src/\"")
        let output = try convert(json: json, supplyTargetFolders: false)

        let demanded = try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.targetFolders]).rendered
        XCTAssertEqual(demanded["input:/pkg/src"], "Folder(path: 'input:/pkg/src').subtreeManifest", "\(demanded)")
        XCTAssertFalse(demanded.keys.contains { $0.hasSuffix("/") }, "\(demanded)")
    }

    /// Under the package folder, the target's sources are what its `sources:` list names —
    /// not the tests beside them, whose Swift would otherwise have made it a Swift target —
    /// and no path in the formula has an empty segment.
    func test_aTargetAtThePackageRootTakesItsSourcesFromItsSourcesList() throws {
        let result = try formula(json: crashReporterManifest, folderContents: crashReporterTree)

        XCTAssertFalse(result.contains("func compilerCrashReporter"), "a C target, got:\n\(result)")
        XCTAssertFalse(result.contains("input:/pkg//"), "got:\n\(result)")
        let product = try productBlock("libCrashReporter.a", in: result)
        XCTAssertTrue(product.contains("{f: 'input:/pkg/Dependencies/protobuf-c/**/*.c', 'input:/pkg/Source/**/*.c', "
                                     + "'input:/pkg/Source/**/*.cpp', 'input:/pkg/Source/**/*.m', 'input:/pkg/Source/**/*.mm'} "),
                      "got:\n\(product)")
        XCTAssertFalse(product.contains(" except "), "no exclusion takes out a source, got:\n\(product)")
    }

    /// Its preprocessor reads the package folder, the public `include` and the
    /// `.headerSearchPath` folder, with the defines as written.
    func test_aTargetAtThePackageRootPreprocessesWithItsHeaderSearchPathAndDefines() throws {
        let result = try formula(json: crashReporterManifest, folderContents: crashReporterTree)

        let preprocessor = try XCTUnwrap(result.components(separatedBy: "\n\n").first { $0.hasPrefix("func preprocessCrashReporter(path)") },
                                         "got:\n\(result)")
        for folder in ["input:/pkg", "input:/pkg/include", "input:/pkg/Dependencies/protobuf-c"] {
            XCTAssertTrue(preprocessor.contains("'\(folder)': Folder(path: '\(folder)').manifest"), "\(folder), got:\n\(preprocessor)")
        }
        XCTAssertTrue(preprocessor.contains("SettingsLiteral(defines: 'SWIFT_PACKAGE=1,PLCR_PRIVATE,PLCRASHREPORTER_PREFIX=', "),
                      "got:\n\(preprocessor)")
    }

    /// `import CrashReporter`: `include/` holds the umbrella `CrashReporter.h` and no module
    /// map, so the header tree carries the one SwiftPM writes (B-55).
    func test_aTargetAtThePackageRootIsImportableThroughItsUmbrellaHeader() throws {
        let result = try formula(json: crashReporterManifest, folderContents: crashReporterTree)

        let headers = try funcDefinition("headersCrashReporter", in: result)
        XCTAssertTrue(headers.contains("'CrashReporter/include/module.modulemap': "
                                     + "ModuleMapWriter(moduleName: 'CrashReporter', umbrellaHeader: 'CrashReporter.h').output"),
                      "got:\n\(headers)")
        XCTAssertTrue(headers.contains("'CrashReporter/Source/PLCrashReport.pb-c.h'"), "got:\n\(headers)")
        XCTAssertFalse(headers.contains("dwarf_stack.hpp"), "excluded, got:\n\(headers)")
        // Searched in the whole text: an empty Swift module tree puts a blank line in the func.
        XCTAssertTrue(result.contains("        'CrashReporter': headersCrashReporter().files\n    ]).files"), "got:\n\(result)")
    }

    /// A C target's resources are a bundle as a Swift target's are, named as SwiftPM
    /// names it, in the product's tree of bundles.
    func test_aCTargetsProcessedResourceIsItsBundle() throws {
        let result = try formula(json: crashReporterManifest, folderContents: crashReporterTree)

        let contents = try funcDefinition("bundleContents_CrashReporter", in: result)
        XCTAssertTrue(contents.contains("'PrivacyInfo.xcprivacy': StaticFile(path: 'input:/pkg/Resources/PrivacyInfo.xcprivacy').output"),
                      "got:\n\(contents)")
        XCTAssertFalse(contents.contains("Info.plist"), "only what the manifest names, got:\n\(contents)")
        XCTAssertEqual(try funcDefinition("bundle_CrashReporter", in: result),
                       "func bundle_CrashReporter() =\n    TreeMerger(under: 'PLCrashReporter_CrashReporter.bundle', "
                     + "input: ['contents': bundleContents_CrashReporter().files]).files")
        XCTAssertTrue(try funcDefinition("bundles_CrashReporter", in: result).contains("'CrashReporter': bundle_CrashReporter().files"),
                      "got:\n\(result)")
    }

    /// On the Mac a resource bundle is laid out as Xcode lays it out: its resources under
    /// `Contents/Resources/` and an Info.plist in `Contents/` naming it by the package's
    /// identity. A flat bundle holding a folder named `Resources` — CodeEditLanguages'
    /// grammars' queries — is read by Foundation as the old layout with that folder for its
    /// resources, and `Bundle.module.resourceURL` is a level too deep (B-77).
    func test_aTargetsBundleIsAlsoLaidOutForTheMac() throws {
        let result = try formula(json: crashReporterManifest, folderContents: crashReporterTree)

        let macBundle = try funcDefinition("macBundle_CrashReporter", in: result)
        XCTAssertTrue(macBundle.contains("TreeMerger(under: 'PLCrashReporter_CrashReporter.bundle/Contents', input: ["), "got:\n\(macBundle)")
        XCTAssertTrue(macBundle.contains("'resources': TreeMerger(under: 'Resources', input: ['contents': bundleContents_CrashReporter().files]).files"),
                      "got:\n\(macBundle)")
        XCTAssertTrue(macBundle.contains("'plist': TreeBuilder(input: ['Info.plist': InfoPlistBuilder(keys: '{"
                                       + "\"CFBundleDevelopmentRegion\":\"en\","
                                       + "\"CFBundleIdentifier\":\"pkg.CrashReporter.resources\","
                                       + "\"CFBundleInfoDictionaryVersion\":\"6.0\","
                                       + "\"CFBundleName\":\"PLCrashReporter_CrashReporter\","
                                       + "\"CFBundlePackageType\":\"BNDL\","
                                       + "\"CFBundleSupportedPlatforms\":[\"MacOSX\"]}').plist]).files"),
                      "got:\n\(macBundle)")
        XCTAssertTrue(try funcDefinition("macBundles_CrashReporter", in: result).contains("'CrashReporter': macBundle_CrashReporter().files"),
                      "got:\n\(result)")
    }

    // MARK: - What a product needs from the linker (B-55)

    /// PLCrashReporter's `.linkedFramework("Foundation")`, and its `.cpp` and `.mm`: the
    /// product's link requirements say both, for whatever links its objects.
    func test_aProductsLinkRequirementsAreItsTargetsFrameworksAndTheCPlusPlusRuntime() throws {
        let result = try formula(json: crashReporterManifest, folderContents: crashReporterTree)

        XCTAssertEqual(try funcDefinition("linking_CrashReporter", in: result),
                       "func linking_CrashReporter() =\n    SettingsLiteral(cxxRuntime: 'true', frameworks: 'Foundation').output")
    }

    private let appOverCLibWithLinkerSettings = """
        {
          "name": "App",
          "dependencies": [],
          "products": [{"name": "App", "targets": ["App"], "type": {"executable": null}}],
          "targets": [
            {"name": "App",  "type": "executable", "path": "Sources/App", "dependencies": [{"byName": ["CLib", null]}],
             "settings": [{"kind": {"linkedFramework": {"_0": "Security"}}, "tool": "linker"}]},
            {"name": "CLib", "type": "regular",    "path": "src",         "dependencies": [],
             "settings": [
               {"kind": {"linkedFramework": {"_0": "Foundation"}}, "tool": "linker"},
               {"kind": {"linkedLibrary": {"_0": "z"}}, "tool": "linker"},
               {"kind": {"unsafeFlags": {"_0": ["-Xlinker", "-v"]}}, "tool": "linker"},
               {"condition": {"config": "debug", "platformNames": []}, "kind": {"linkedLibrary": {"_0": "debugonly"}}, "tool": "linker"}
             ]}
          ]
        }
        """

    /// An executable links every framework and library the targets it reaches name — its
    /// own Swift target's and its C target's — each once, through its own linker. One
    /// conditional on a configuration is not carried, and asks for no platform.
    func test_aProductsLinkerTakesTheUnionOfItsTargetsLinkerSettings() throws {
        let output = try convert(json: appOverCLibWithLinkerSettings, folderContents: cFolders)
        XCTAssertEqual(output.inputWireSpecs[SwiftFormulaConverter.linkerConfiguration] ?? [:], [:])
        let result = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput]).expectValue().resolveAsString()

        XCTAssertEqual(try funcDefinition("linking_App", in: result),
                       "func linking_App() =\n    SettingsLiteral(frameworks: 'Foundation,Security', libraries: 'z').output")
        XCTAssertTrue(try productBlock("App", in: result).contains("linkRequirements: ['App': linking_App().output]"),
                      "got:\n\(result)")
    }

    /// A product that needs nothing still defines its func, empty, so an app can name it
    /// without knowing; its own linker is not wired to it.
    func test_aProductThatNeedsNothingDefinesAnEmptyLinkRequirementsFunc() throws {
        let result = try formula(json: appOverCLib, folderContents: cFolders)

        XCTAssertEqual(try funcDefinition("linking_App", in: result), "func linking_App() =\n    SettingsLiteral().output")
        XCTAssertFalse(try productBlock("App", in: result).contains("linkRequirements"), "got:\n\(result)")
    }

    private var platformConditionalManifest: String {
        appOverCLibWithLinkerSettings.replacingOccurrences(
            of: #"{"kind": {"linkedLibrary": {"_0": "z"}}, "tool": "linker"}"#,
            with: #"{"condition": {"platformNames": ["macos"]}, "kind": {"linkedLibrary": {"_0": "z"}}, "tool": "linker"}, "#
                + #"{"condition": {"platformNames": ["ios", "tvos"]}, "kind": {"linkedFramework": {"_0": "UIKit"}}, "tool": "linker"}"#)
    }

    /// A `.when(platforms:)` linker setting is decided for the platform being built: the
    /// SDK the product's linker links against, read from its settings, which the conversion
    /// asks for and waits on.
    func test_aPlatformConditionalLinkerSettingHoldsForTheSDKTheLinkerUses() throws {
        let waiting = try convert(json: platformConditionalManifest, folderContents: cFolders)
        let demanded = try XCTUnwrap(waiting.inputWireSpecs[SwiftFormulaConverter.linkerConfiguration]).rendered
        XCTAssertEqual(Array(demanded.values), [
            "ConfigFilter(prefix: 'swift.linker', input: [\"config\": ConfigMerger("
            + "base: [\"machine\": StaticFile(path: 'input:/pkg/semel.machine.config').output], "
            + "override: [\"project\": StaticFile(path: 'input:/pkg/semel.config').output]).output]).output",
        ])
        XCTAssertEqual(try pendingCondition(waiting), .inputsWithoutValue(kind: .platformSettings, paths: ["swift.linker"]))

        let forIOS = try formula(json: platformConditionalManifest, folderContents: cFolders,
                                 linkerSettings: "sdk=iphonesimulator\ntarget=arm64-apple-ios18.0-simulator")
        XCTAssertEqual(try funcDefinition("linking_App", in: forIOS),
                       "func linking_App() =\n    SettingsLiteral(frameworks: 'Foundation,Security,UIKit').output")

        // No `sdk` is the linker's own default, the Mac.
        let forMac = try formula(json: platformConditionalManifest, folderContents: cFolders, linkerSettings: "target=arm64-apple-macosx13.0")
        XCTAssertEqual(try funcDefinition("linking_App", in: forMac),
                       "func linking_App() =\n    SettingsLiteral(frameworks: 'Foundation,Security', libraries: 'z').output")
    }

    /// `.S` and `.s` sources are a C target's sources (PLCrashReporter's
    /// `PLCrashAsyncThread_current.S`): a `.S` preprocessed with the rest, a `.s` compiled
    /// as it is, both under the target's exclusions; C alone needs no C++ runtime.
    func test_aCTargetsAssemblyIsCompiledAndOnlyAPreprocessedOneIsPreprocessed() throws {
        let json = cLibJSON("\"exclude\": [\"Tests\"]")
        var tree = cLibTree
        tree["input:/pkg/src/lib"] = [file("util.c"), file("util.h"), file("thread.S"), file("base.s")]
        tree["input:/pkg/src/Tests"] = [file("test.c"), file("probe.s")]
        let result = try formula(json: json, folderContents: tree)

        let product = try productBlock("App", in: result)
        XCTAssertTrue(product.contains("{f: 'input:/pkg/src/**/*.S', 'input:/pkg/src/**/*.c' except 'input:/pkg/src/Tests/**'} "
                                     + "\"%%f%%.o\": ClangCompiler("), "got:\n\(product)")
        XCTAssertTrue(product.contains("{f: 'input:/pkg/src/**/*.s' except 'input:/pkg/src/Tests/**'} \"%%f%%.o\": ClangCompiler("
                                     + "configuration: ['config': ConfigFilter(prefix: 'clang.compiler'"), "got:\n\(product)")
        XCTAssertTrue(product.contains("input: [\"%%f%%\": StaticFile(path: f)])"), "got:\n\(product)")
        XCTAssertEqual(try funcDefinition("linking_App", in: result), "func linking_App() =\n    SettingsLiteral().output")
    }

    /// A target of assembly alone is a C target, as SwiftPM counts it.
    func test_aTargetOfAssemblyAloneIsACTarget() throws {
        let result = try formula(json: appOverCLib, folderContents: ["input:/pkg/src": [file("answer.S")],
                                                                     "input:/pkg/extensions": [file("table.c")]])

        XCTAssertFalse(result.contains("func compilerCLib"), "got:\n\(result)")
        XCTAssertTrue(try productBlock("App", in: result).contains("{f: 'input:/pkg/src/**/*.S'}"), "got:\n\(result)")
    }

    // MARK: - A build root shared by several packages (B-56)

    /// `SwiftFormulaConverter(path: <Timeline>, root: <.>)`: the config and the vendored
    /// dependencies are read from `root`, so a formula that includes several packages
    /// vendors and compiles their common closure once. Sources stay under the package.
    private func convert(packageFolder: String, root: String, json: String) throws -> ProcessOutput {
        let manifest  = FolderManifest(baseFolderPath: packageFolder, entries: [])
        let converter = try SwiftFormulaConverter(thisNode: NodeRecord(id: 1, kind: SwiftFormulaConverter.kind,
                                                                       name: nil, properties: ["root": root],
                                                                       scheduled: false, identity: nil))
        return try converter.process(input: ProcessInput(inputValues: [
            SwiftFormulaConverter.packageFolder: ["folder": .value(try manifest.toJSON().intern())],
            SwiftFormulaConverter.packageJSON:   ["json":   .value(try json.intern())],
            SwiftFormulaConverter.externalPackageJSONs: [:],
        ]))
    }

    func test_aBuildRootMovesDependenciesAndConfigButNotSources() throws {
        let output = try convert(packageFolder: "input:/repo/Packages/DatabaseModels",
                                 root: "input:/repo/Packages",
                                 json: sourceControlManifest())

        XCTAssertEqual(try externalSpecs(output).keys.sorted(),
                       ["input:/repo/Packages/Dependencies/GRDB.swift"],
                       "the dependency lives under the root, not under the package")
        let reader = try XCTUnwrap(try externalSpecs(output)["input:/repo/Packages/Dependencies/GRDB.swift"])
        XCTAssertTrue(reader.contains("input:/repo/Packages/semel.config"), "config beside the root, got:\n\(reader)")
        XCTAssertFalse(reader.contains("DatabaseModels/semel.config"), "got:\n\(reader)")
    }

    func test_withoutARootThePackageFolderIsTheRoot() throws {
        let output = try convert(packageFolder: "input:/repo/Packages/DatabaseModels", json: sourceControlManifest())

        XCTAssertEqual(try externalSpecs(output).keys.sorted(),
                       ["input:/repo/Packages/DatabaseModels/Dependencies/GRDB.swift"])
    }
}
