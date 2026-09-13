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

    private func convert(packageFolder: String = "input:/pkg",
                         json: String,
                         externalManifests: [String: String] = [:]) throws -> ProcessOutput {
        let manifest = FolderManifest(baseFolderPath: packageFolder, entries: [])
        var externalValues = [String: NodeValue]()
        for (path, externalJSON) in externalManifests {
            externalValues[path] = .value(try externalJSON.intern())
        }
        let input = ProcessInput(inputValues: [
            SwiftFormulaConverter.packageFolder:        ["folder": .value(try manifest.toJSON().intern())],
            SwiftFormulaConverter.packageJSON:          ["json":   .value(try json.intern())],
            SwiftFormulaConverter.externalPackageJSONs: externalValues,
        ])
        return try makeConverter().process(input: input)
    }

    private func formula(packageFolder: String = "input:/pkg",
                         json: String,
                         externalManifests: [String: String] = [:]) throws -> String {
        let output = try convert(packageFolder: packageFolder, json: json, externalManifests: externalManifests)
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
        try XCTUnwrap(output.inputWireSpecs[SwiftFormulaConverter.externalPackageJSONs])
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
    /// empty `Configuration()` it throws before a single target is compiled.
    func test_theExternalPackageReaderIsWiredToASelectorForItsOwnNamespace() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest())

        let spec = try XCTUnwrap(try externalSpecs(output)["input:/repo/DatabaseModels/Dependencies/GRDB.swift"])
        XCTAssertTrue(spec.contains("ConfigFilter(prefix: 'swift.packageReader'"),
                      "got:\n\(spec)")
        XCTAssertFalse(spec.contains("Configuration().output"),
                       "an empty Configuration leaves the reader with no toolDescriptor, got:\n\(spec)")
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
            "Configuration(moduleName: 'Helper', inherit: ['settings': "
            + "ConfigFilter(prefix: 'swift.compiler', "
            + "input: ['config': StaticFile(path: 'input:/pkg/semel.config').output]).output]).output"),
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
            "Configuration(linkage: 'executable', outputName: 'semel', inherit: ['settings': "
            + "ConfigFilter(prefix: 'swift.linker', "
            + "input: ['config': StaticFile(path: 'input:/pkg/semel.config').output]).output]).output"),
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

    /// The reason text on a pending output, which is what the user actually sees.
    private func pendingReason(_ output: ProcessOutput) throws -> String {
        let value = try XCTUnwrap(output.outputValues[SwiftFormulaConverter.formulaOutput])
        guard case .noValue(let reason) = value, case .error(let hash) = reason else {
            XCTFail("expected a pending output, got \(value)")
            return ""
        }
        return try hash.resolveAsString()
    }

    /// A vendored package that is not there stalls the whole conversion, and the old
    /// message named only the path it was waiting on — which says nothing about why that
    /// path is expected, or that this build system never fetches anything.
    func test_explainsWhichRepositoryAVendoredPathIsWaitingFor() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels", json: sourceControlManifest())

        let reason = try pendingReason(output)
        XCTAssertTrue(reason.contains("input:/repo/DatabaseModels/Dependencies/GRDB.swift"), "got:\n\(reason)")
        XCTAssertTrue(reason.contains("https://github.com/groue/GRDB.swift.git"),
                      "should name the repository the path stands for, got:\n\(reason)")
    }

    func test_saysThatAVendoredPackageIsNeverFetched() throws {
        let reason = try pendingReason(
            try convert(packageFolder: "input:/repo/DatabaseModels", json: sourceControlManifest()))

        XCTAssertTrue(reason.lowercased().contains("never fetch"),
                      "should say why nothing is downloading it, got:\n\(reason)")
    }

    /// A local path dependency has no repository behind it, so it must not claim one.
    func test_describesAMissingLocalPathDependencyDifferently() throws {
        let reason = try pendingReason(try convert(packageFolder: "input:/repo/App", json: """
            {
              "name": "App",
              "dependencies": [{"fileSystem": [{"identity": "helper", "path": "../Helper"}]}],
              "products": [{"name": "App", "targets": ["App"], "type": {"executable": null}}],
              "targets": [{"name": "App", "type": "executable", "path": "App",
                           "dependencies": [{"product": ["Helper", "helper", null, null]}]}]
            }
            """))

        XCTAssertTrue(reason.contains("input:/repo/Helper"), "got:\n\(reason)")
        XCTAssertFalse(reason.contains("http"), "a path dependency has no repository, got:\n\(reason)")
    }

    // MARK: - sourceControl dependencies

    /// This build system never fetches anything, so a git dependency is resolved to a
    /// copy vendored under the root package's `Dependencies` folder — flat, one copy per
    /// package, where `semel-vendor` puts it. The name comes from the URL, not from SPM's
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
        let reason = try pendingReason(try convert(packageFolder: "input:/repo/App", json: registryManifest))

        XCTAssertTrue(reason.contains("input:/repo/App/Dependencies/mona.LinkedList"), "got:\n\(reason)")
        XCTAssertTrue(reason.contains("registry package mona.LinkedList"),
                      "should say the path stands for a registry package, got:\n\(reason)")
        XCTAssertFalse(reason.contains("local path"), "a registry package is not a path dependency, got:\n\(reason)")
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
}
