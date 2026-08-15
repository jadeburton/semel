//
//  SwiftFormulaConverterTests.swift
//  build_system_tests
//
//  The converter turns a `swift package dump-package` manifest into the .fmla text
//  ProjectBuilder consumes, so the interesting assertions are all about which blocks
//  come out of it for a given manifest shape.
//

@testable import BuildSystemCore
import XCTest
import SemelNodeKit

final class SwiftFormulaConverterTests: BuildSystemTestCase {

    // MARK: - Helpers

    private func makeConverter() throws -> SwiftFormulaConverter {
        try SwiftFormulaConverter(thisNode: Node(id: 1, kind: SwiftFormulaConverter.kind))
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

    private func externalExpectations(_ output: ProcessOutput) throws -> [String: String] {
        try XCTUnwrap(output.inputWireExpectations[SwiftFormulaConverter.externalPackageJSONs])
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
    /// SwiftLinkerTool for it leaves the required `input` port with no wires, which fails
    /// the whole ProjectBuilder with requiredPortUnwired.
    func test_skipsProductsThatVendOnlySystemLibraries() throws {
        let result = try formula(json: grdbShapedManifest)

        let productLabels = result.components(separatedBy: "\n\n")
            .filter { $0.hasPrefix("product ") }
            .compactMap { $0.components(separatedBy: "'").dropFirst().first }

        XCTAssertFalse(productLabels.contains { $0.contains("GRDBSQLite") },
                       "GRDBSQLite vends only a system library, got: \(productLabels)")
        XCTAssertTrue(productLabels.contains("libGRDB.dylib"),
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
        let block = try productBlock("libGRDB.dylib", in: try formula(json: grdbShapedManifest))

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
        let block = try productBlock("build_system", in: try rootFormula())

        XCTAssertTrue(block.contains("'GRDBSQLite': Folder(path: 'input:/repo/GRDB.swift/Sources/GRDBSQLite').manifest"),
                      "got:\n\(block)")
    }

    // MARK: - Product file names

    /// The product's formula label becomes its file name in the output file system, so it
    /// has to be the name the linker actually writes. A library is linked as
    /// lib<name>.dylib but was published as the bare product name, so a dylib appeared
    /// with neither the lib prefix nor the extension.
    func test_publishesALibraryUnderItsLinkedFileName() throws {
        let result = try formula(json: grdbShapedManifest)

        XCTAssertTrue(result.contains("product 'libGRDB.dylib' ="), "got:\n\(result)")
        XCTAssertTrue(result.contains("outputName: 'libGRDB.dylib'"), "got:\n\(result)")
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
                                 externalManifests: ["input:/repo/GRDB.swift": grdbShapedManifest])

        let block = try funcDefinition("compilerDatabaseModels", in: result)
        XCTAssertTrue(block.contains("'GRDBSQLite': Folder(path: 'input:/repo/GRDB.swift/Sources/GRDBSQLite').manifest"),
                      "got:\n\(block)")
    }

    /// The indirect import still wires the module itself, not a compiler func for the
    /// system library — that would try to compile a directory of headers.
    func test_anIndirectlyImportedSystemLibraryIsNotWiredAsASwiftModule() throws {
        let result = try formula(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest(),
                                 externalManifests: ["input:/repo/GRDB.swift": grdbShapedManifest])

        let block = try funcDefinition("compilerDatabaseModels", in: result)
        XCTAssertTrue(block.contains("'GRDB': compilerGRDB().swiftmodule"), "got:\n\(block)")
        XCTAssertFalse(block.contains("compilerGRDBSQLite"), "got:\n\(block)")
    }

    // MARK: - Explicit source lists

    /// The converter cannot enumerate files — it only wires folders — so a target's
    /// `sources:`/`exclude:` lists have to travel to SwiftCompilerTool as configuration
    /// and be applied there, during discovery.
    func test_carriesAnExplicitSourcesListIntoTheCompilerConfiguration() throws {
        let result = try formula(json: """
            {
              "name": "build_system",
              "dependencies": [],
              "products": [],
              "targets": [
                {"name": "build_system", "type": "executable", "path": "build_system",
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

    /// A target with neither list must produce exactly the configuration it did before,
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

        XCTAssertTrue(result.contains("Configuration(moduleName: 'Helper').output"), "got:\n\(result)")
    }

    // MARK: - Implicit executable products

    /// This repository's own root manifest declares no products at all — `swift build`
    /// builds the executable target directly. Iterating only declared products emitted an
    /// empty formula and produced nothing, with no error to say why.
    func test_emitsAnExecutableTargetThatNoProductDeclares() throws {
        let result = try formula(json: """
            {
              "name": "build_system",
              "dependencies": [],
              "products": [],
              "targets": [
                {"name": "build_system", "type": "executable", "path": "build_system", "dependencies": []}
              ]
            }
            """)

        XCTAssertTrue(result.contains("product 'build_system' ="), "got:\n\(result)")
        XCTAssertTrue(result.contains("func compilerbuild_system()"), "got:\n\(result)")
    }

    /// An implicit product is an executable, not a library — it must not be linked as
    /// libbuild_system.dylib.
    func test_linksAnImplicitExecutableProductAsAnExecutable() throws {
        let result = try formula(json: """
            {
              "name": "build_system",
              "dependencies": [],
              "products": [],
              "targets": [
                {"name": "build_system", "type": "executable", "path": "build_system", "dependencies": []}
              ]
            }
            """)

        XCTAssertTrue(result.contains("Configuration(dynamicLibrary: 'false', outputName: 'build_system')"),
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
          "name": "build_system",
          "dependencies": [{"fileSystem": [{"identity": "buildsystemcore", "path": "BuildSystemCore"}]}],
          "products": [],
          "targets": [
            {"name": "BuildSystemCLI", "type": "regular", "path": "build_system/CommandInterpreter",
             "dependencies": [{"product": ["BuildSystemCore", "BuildSystemCore", null, null]}]},
            {"name": "build_system", "type": "executable", "path": "build_system",
             "sources": ["main.swift"],
             "dependencies": [{"byName": ["BuildSystemCLI", null]},
                              {"product": ["BuildSystemCore", "BuildSystemCore", null, null]}]},
            {"name": "BuildSystemCLITests", "type": "test", "path": "build_system/Tests",
             "dependencies": [{"byName": ["BuildSystemCLI", null]}]}
          ]
        }
        """

    /// BuildSystemCore as it really is: a path dependency of the root manifest that
    /// itself pulls in GRDB by git URL. Together with grdbShapedManifest this reproduces
    /// the whole production chain — root -> BuildSystemCore -> GRDB -> GRDBSQLite.
    private let buildSystemCoreManifest = """
        {
          "name": "BuildSystemCore",
          "dependencies": [
            {"sourceControl": [{"identity": "grdb.swift",
                                "location": {"remote": [{"urlString": "https://github.com/groue/GRDB.swift.git"}]}}]}
          ],
          "products": [
            {"name": "BuildSystemCore", "targets": ["BuildSystemCore"], "type": {"library": ["automatic"]}}
          ],
          "targets": [
            {"name": "BuildSystemCore", "type": "regular", "path": "Sources/BuildSystemCore",
             "dependencies": [{"product": ["GRDB", "GRDB.swift", null, null]}]}
          ]
        }
        """

    private func rootFormula() throws -> String {
        try formula(packageFolder: "input:/repo",
                    json: rootManifestShape,
                    externalManifests: ["input:/repo/BuildSystemCore": buildSystemCoreManifest,
                                        "input:/repo/GRDB.swift":      grdbShapedManifest])
    }

    func test_buildsTheExecutableFromThisRepositorysOwnRootManifest() throws {
        let result = try rootFormula()

        XCTAssertTrue(result.contains("product 'build_system' ="), "got:\n\(result)")
        XCTAssertTrue(result.contains("'build_system.o': compilerbuild_system().object"), "got:\n\(result)")
        XCTAssertTrue(result.contains("'BuildSystemCLI.o': compilerBuildSystemCLI().object"), "got:\n\(result)")
    }

    /// The executable's folder also holds BuildSystemCLI's sources and the XCTest target,
    /// so the walk has to be held to `sources: ["main.swift"]`.
    func test_confinesTheExecutableTargetToItsDeclaredSources() throws {
        let result = try rootFormula()

        let block = try funcDefinition("compilerbuild_system", in: result)
        XCTAssertTrue(block.contains("sourcePaths: 'main.swift'"), "got:\n\(block)")
        XCTAssertTrue(block.contains("Folder(path: 'input:/repo/build_system').manifest"), "got:\n\(block)")
    }

    func test_neverBuildsTheTestTarget() throws {
        let result = try rootFormula()

        XCTAssertFalse(result.contains("BuildSystemCLITests"), "got:\n\(result)")
    }

    /// The failure this whole chain produced: BuildSystemCLI imports only BuildSystemCore,
    /// but loading that module needs GRDB — and GRDB in turn needs GRDBSQLite's module map.
    /// Both have to reach a target three packages away that names neither.
    func test_reachesThroughThreePackagesToTheSystemLibrary() throws {
        let block = try funcDefinition("compilerBuildSystemCLI", in: try rootFormula())

        XCTAssertTrue(block.contains("'GRDB': compilerGRDB().swiftmodule"), "got:\n\(block)")
        XCTAssertTrue(block.contains("'GRDBSQLite': Folder(path: 'input:/repo/GRDB.swift/Sources/GRDBSQLite').manifest"),
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
        XCTAssertTrue(reason.contains("input:/repo/GRDB.swift"), "got:\n\(reason)")
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
              "targets": [{"name": "App", "type": "executable", "path": "App", "dependencies": []}]
            }
            """))

        XCTAssertTrue(reason.contains("input:/repo/Helper"), "got:\n\(reason)")
        XCTAssertFalse(reason.contains("http"), "a path dependency has no repository, got:\n\(reason)")
    }

    // MARK: - sourceControl dependencies

    /// This build system never fetches anything, so a git dependency is resolved to a
    /// copy vendored beside the package that needs it. The name comes from the URL, not
    /// from SPM's `identity` — identity is lowercased ("grdb.swift") and so cannot name
    /// a directory on a case-sensitive filesystem.
    func test_resolvesASourceControlDependencyToAVendoredSiblingDirectory() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels", json: sourceControlManifest())

        XCTAssertEqual(try externalExpectations(output).keys.sorted(), ["input:/repo/GRDB.swift"])
    }

    func test_readsThePackageManifestOfAVendoredSourceControlDependency() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels", json: sourceControlManifest())

        let expectation = try XCTUnwrap(try externalExpectations(output)["input:/repo/GRDB.swift"])
        XCTAssertTrue(expectation.contains("input:/repo/GRDB.swift/Package.swift"), "got: \(expectation)")
    }

    /// The end of the chain: once the vendored manifest arrives, the dependency's product
    /// resolves to a real target and its swiftmodule is wired into the compile. Without
    /// this the target compiles alone and fails with "no such module 'GRDB'".
    func test_wiresTheModuleOfAVendoredSourceControlDependency() throws {
        let result = try formula(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest(),
                                 externalManifests: ["input:/repo/GRDB.swift": grdbShapedManifest])

        XCTAssertTrue(result.contains("'GRDB': compilerGRDB().swiftmodule"), "got:\n\(result)")
        XCTAssertTrue(result.contains("Folder(path: 'input:/repo/GRDB.swift/GRDB').manifest"),
                      "GRDB's sources should resolve against the vendored root, got:\n\(result)")
    }

    func test_stripsTheGitSuffixWhenNamingTheVendoredDirectory() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest(url: "https://github.com/groue/GRDB.swift"))

        XCTAssertEqual(try externalExpectations(output).keys.sorted(), ["input:/repo/GRDB.swift"])
    }

    func test_resolvesScpStyleGitURLs() throws {
        let output = try convert(packageFolder: "input:/repo/DatabaseModels",
                                 json: sourceControlManifest(url: "git@github.com:groue/GRDB.swift.git"))

        XCTAssertEqual(try externalExpectations(output).keys.sorted(), ["input:/repo/GRDB.swift"])
    }

    /// A package dependency of a package dependency still has to resolve, and a vendored
    /// checkout sits beside the package that named it — so the walk must resolve each
    /// sourceControl URL against the manifest that declared it, not against the root.
    func test_resolvesASourceControlDependencyDeclaredByAnExternalPackage() throws {
        let output = try convert(packageFolder: "input:/repo/BuildSystemCore", json: """
            {
              "name": "BuildSystemCore",
              "dependencies": [{"fileSystem": [{"identity": "databasemodels", "path": "../DatabaseModels"}]}],
              "products": [
                {"name": "BuildSystemCore", "targets": ["BuildSystemCore"], "type": {"library": ["automatic"]}}
              ],
              "targets": [
                {"name": "BuildSystemCore", "type": "regular", "path": "Sources/BuildSystemCore",
                 "dependencies": [{"product": ["DatabaseModels", "DatabaseModels", null, null]}]}
              ]
            }
            """,
            externalManifests: ["input:/repo/DatabaseModels": sourceControlManifest()])

        XCTAssertEqual(try externalExpectations(output).keys.sorted(),
                       ["input:/repo/DatabaseModels", "input:/repo/GRDB.swift"])
    }
}
