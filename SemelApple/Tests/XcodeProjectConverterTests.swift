//
//  XcodeProjectConverterTests.swift
//  SemelAppleTests
//
//  The node's own work is the waiting: the project file a pass after creation, then the
//  xcconfig files it names and the folders it walks, and only then the formula.
//

@testable import SemelApple
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class XcodeProjectConverterTests: SemelAppleTestCase {

    private let projectPath = "input:/repo/IceCubesApp.xcodeproj"
    private var projectFile: String { "\(projectPath)/project.pbxproj" }

    /// The fixture's synchronized folder that no target owns: the converter looks into it
    /// for local packages as into every synchronized folder.
    private let notificationsFolder = "input:/repo/IceCubesNotifications"

    /// `folders` as given — the listing of each folder by path, answered as the tree of
    /// each (B-135) — with the unowned folder holding a source and no package unless the
    /// test says otherwise: a test about something else still has it answered.
    private func process(projectFile: NodeValue? = nil,
                         xcconfigs: [String: NodeValue] = [:],
                         folders: [String: NodeValue] = [:]) throws -> ProcessOutput {
        let node = try XcodeProjectConverter(thisNode: NodeRecord(id: 1, kind: XcodeProjectConverter.kind, name: nil,
                                                                  properties: ["path": projectPath], scheduled: false, identity: nil))
        var folders = folders
        if folders[notificationsFolder] == nil {
            folders[notificationsFolder] = try manifestValue(notificationsFolder, files: ["NotificationService.swift"])
        }
        var inputs: [String: [String: NodeValue]] = [XcodeProjectConverter.xcconfigs: xcconfigs,
                                                     XcodeProjectConverter.folders: try treeValues(from: folders)]
        if let projectFile {
            inputs[XcodeProjectConverter.projectFile] = [self.projectFile: projectFile]
        }
        return try node.process(input: ProcessInput(inputValues: inputs))
    }

    private var fixtureProject: NodeValue {
        get throws { .value(try XcodeProjectTests.fixture.intern()) }
    }

    private func isPending(_ output: ProcessOutput) -> Bool {
        if case .noValue(.pending) = output.outputValues[XcodeProjectConverter.formulaOutput] ?? .noValue(reason: .pending) {
            return true
        }
        return false
    }

    func test_demandsTheProjectFileFirst() throws {
        let output = try process()

        XCTAssertEqual(output.inputWireSpecs[XcodeProjectConverter.projectFile]?.rendered,
                       [projectFile: "StaticFile(path: '\(projectFile)').output"])
        XCTAssertTrue(isPending(output))
    }

    /// With the project read, the xcconfig it names and the application's folder are
    /// demanded together, with every other synchronized folder, where a local package may
    /// be; the formula waits for all of them.
    func test_demandsTheXcconfigAndTheTargetFolderOnceTheProjectHasArrived() throws {
        let node = try XcodeProjectConverter(thisNode: NodeRecord(id: 1, kind: XcodeProjectConverter.kind, name: nil,
                                                                  properties: ["path": projectPath], scheduled: false, identity: nil))
        let output = try node.process(input: ProcessInput(inputValues: [XcodeProjectConverter.projectFile: [projectFile: try fixtureProject]]))

        XCTAssertEqual(output.inputWireSpecs[XcodeProjectConverter.xcconfigs]?.rendered,
                       ["input:/repo/App.xcconfig": "StaticFile(path: 'input:/repo/App.xcconfig').output"])
        XCTAssertEqual(output.inputWireSpecs[XcodeProjectConverter.folders]?.rendered,
                       ["input:/repo/IceCubesApp": "Folder(path: 'input:/repo/IceCubesApp').subtreeManifest",
                        "input:/repo/IceCubesShareExtension": "Folder(path: 'input:/repo/IceCubesShareExtension').subtreeManifest",
                        "input:/repo/IceCubesNotifications": "Folder(path: 'input:/repo/IceCubesNotifications').subtreeManifest"],
                       "the embedded extension's folder is read too, and the folder no target owns is looked into")
        XCTAssertTrue(isPending(output))
    }

    private var extensionFolder: (String, NodeValue) {
        get throws { ("input:/repo/IceCubesShareExtension", try manifestValue("input:/repo/IceCubesShareExtension", files: ["Share.swift"])) }
    }

    /// The folder is one tree, however deep (B-135): what is asked for is the target's
    /// folders and the synchronized folders, never a folder below one.
    func test_asksForEachFolderAsOneTree() throws {
        let output = try process(projectFile: try fixtureProject,
                                 xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(documentHash: try "absent".intern()))],
                                 folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp",
                                                                                         files: ["App.swift"],
                                                                                         folders: ["Views", "Assets.xcassets"]),
                                           "input:/repo/IceCubesApp/Views": try manifestValue("input:/repo/IceCubesApp/Views", folders: ["Rows"])])

        XCTAssertEqual(output.inputWireSpecs[XcodeProjectConverter.folders]?.keys.sorted(),
                       ["input:/repo/IceCubesApp", "input:/repo/IceCubesNotifications", "input:/repo/IceCubesShareExtension"])
        XCTAssertTrue(isPending(output), "the extension's folder has not arrived")
    }

    /// Not into a catalog, which its own compiler walks, nor a bundle, copied whole by a
    /// node that walks it itself, nor a documentation catalog, which is not built: what is
    /// below them is never read, so a subtree the store cannot give back there changes
    /// nothing, where one under a group would be the conversion's error. (A folder directly
    /// in a synchronized folder is read one level for a package, as it always was asked
    /// about, unless it is a catalog; so the bundle and the documentation are a level down.)
    func test_doesNotReadIntoACatalogAFolderCopiedWholeOrOneNotBuilt() throws {
        let unreadable = String(repeating: "0", count: 64)
        func tree(_ entries: [FolderSubtreeEntry]) throws -> NodeValue {
            .value(try FolderSubtreeManifest(entries: entries).toJSON().intern())
        }
        let views = try FolderSubtreeManifest(entries: [
            FolderSubtreeEntry(name: "Row.swift", isFolder: false, isPinned: true),
            FolderSubtreeEntry(name: "Sounds.bundle", isFolder: true, isPinned: true, subtree: unreadable),
            FolderSubtreeEntry(name: "Guide.docc", isFolder: true, isPinned: true, subtree: unreadable),
        ])
        let app = try tree([
            FolderSubtreeEntry(name: "App.swift", isFolder: false, isPinned: true),
            FolderSubtreeEntry(name: "Assets.xcassets", isFolder: true, isPinned: true, subtree: unreadable),
            FolderSubtreeEntry(name: "Views", isFolder: true, isPinned: true, subtree: try views.toJSON().intern()),
        ])
        let node = try XcodeProjectConverter(thisNode: NodeRecord(id: 1, kind: XcodeProjectConverter.kind, name: nil,
                                                                  properties: ["path": projectPath], scheduled: false, identity: nil))
        var folders = try treeValues(from: [notificationsFolder: try manifestValue(notificationsFolder, files: ["NotificationService.swift"]),
                                            try extensionFolder.0: try extensionFolder.1])
        folders["input:/repo/IceCubesApp"] = app
        let inputs: [String: [String: NodeValue]] = [
            XcodeProjectConverter.projectFile: [projectFile: try fixtureProject],
            XcodeProjectConverter.xcconfigs:   ["input:/repo/App.xcconfig": .value(try "BUNDLE_ID_PREFIX = com.example".intern())],
            XcodeProjectConverter.folders:     folders,
        ]

        let output = try node.process(input: ProcessInput(inputValues: inputs))
        XCTAssertNoThrow(try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue())

        folders["input:/repo/IceCubesApp"] = try tree([FolderSubtreeEntry(name: "Views", isFolder: true, isPinned: true, subtree: unreadable)])
        XCTAssertThrowsError(try node.process(input: ProcessInput(inputValues: inputs.merging([XcodeProjectConverter.folders: folders]) { $1 })))
    }

    /// Everything there: the formula names the executable, the catalog, the plain
    /// resource under the walked subfolder, and the bundle — with the xcconfig's value
    /// resolved into the bundle identifier.
    func test_emitsTheFormulaOnceTheWalkIsComplete() throws {
        let output = try process(
            projectFile: try fixtureProject,
            xcconfigs: ["input:/repo/App.xcconfig": .value(try "BUNDLE_ID_PREFIX = com.example".intern())],
            folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp",
                                                                    files: ["App.swift", "Info.plist"],
                                                                    folders: ["Fonts", "Assets.xcassets"]),
                      "input:/repo/IceCubesApp/Fonts": try manifestValue("input:/repo/IceCubesApp/Fonts", files: ["Mono.ttf"]),
                      try extensionFolder.0: try extensionFolder.1])

        let formula = try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/Ice Cubes' ="), formula)
        XCTAssertTrue(formula.contains("'Assets.xcassets': Folder(path: 'input:/repo/IceCubesApp/Assets.xcassets').manifest"), formula)
        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/Mono.ttf' = StaticFile(path: 'input:/repo/IceCubesApp/Fonts/Mono.ttf').output"), formula)
        XCTAssertTrue(formula.contains("\"CFBundleIdentifier\":\"com.example.IceCubesApp\""), formula)
        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/' = TreeMerger("), formula)
    }

    /// An include is known only once the file naming it has arrived: it is demanded then,
    /// as one more `StaticFile` on the same port, and the formula waits for it — the
    /// value it defines reaches the bundle identifier. An `#include?` of a file outside the
    /// input file system is not demanded and not missed.
    func test_demandsWhatAnXcconfigIncludesAndWaitsForIt() throws {
        let app = "input:/repo/App.xcconfig"
        let base = "input:/repo/Config/Base.xcconfig"
        let appText = "#include? \"../../Outside.xcconfig\"\n#include \"Config/Base.xcconfig\"\nDEVELOPMENT_TEAM = TEAM"
        let folders = ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp", files: ["App.swift"]),
                       try extensionFolder.0: try extensionFolder.1]

        let first = try process(projectFile: try fixtureProject, xcconfigs: [app: .value(try appText.intern())], folders: folders)

        XCTAssertEqual(first.inputWireSpecs[XcodeProjectConverter.xcconfigs]?.keys.sorted(), [app, base])
        XCTAssertTrue(isPending(first))

        let second = try process(projectFile: try fixtureProject,
                                 xcconfigs: [app: .value(try appText.intern()),
                                             base: .value(try "BUNDLE_ID_PREFIX = com.included".intern())],
                                 folders: folders)

        let formula = try XCTUnwrap(second.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        XCTAssertTrue(formula.contains("\"CFBundleIdentifier\":\"com.included.IceCubesApp\""), formula)
    }

    /// A plain include with no file is read as empty, and named as the cause of what it
    /// leaves undefined, the way a missing root is.
    func test_reportsAMissingIncludeAsTheCauseOfTheUndefinedSettings() throws {
        let output = try process(
            projectFile: try fixtureProject,
            xcconfigs: ["input:/repo/App.xcconfig": .value(try "#include \"Base.xcconfig\"".intern()),
                        "input:/repo/Base.xcconfig": .noValue(reason: .initializing)],
            folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp", files: ["App.swift"]),
                      try extensionFolder.0: try extensionFolder.1])

        let document = try XCTUnwrap(try XCTUnwrap(output.outputValues[XcodeProjectConverter.infoLog]).errorDocument,
                                     "expected the missing include on infoLog as an error")
        guard case .engine(.xcconfigMissing(let paths, let undefined)) = document.diagnostic else {
            return XCTFail("expected the missing xcconfig, got \(document)")
        }
        XCTAssertEqual(paths, ["input:/repo/Base.xcconfig"])
        XCTAssertTrue(undefined.contains("BUNDLE_ID_PREFIX"), "\(undefined)")
        XCTAssertEqual(document.subject, .project(path: "input:/repo/IceCubesApp.xcodeproj"))
    }

    /// The xcconfig a fresh clone lacks is an empty layer, not a stall: the formula is
    /// emitted with the reference unresolved for the plist builder to report.
    func test_aMissingXcconfigDoesNotStallTheConversion() throws {
        let output = try process(
            projectFile: try fixtureProject,
            xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(documentHash: try "absent".intern()))],
            folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp", files: ["App.swift"]),
                      try extensionFolder.0: try extensionFolder.1])

        let formula = try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        XCTAssertTrue(formula.contains("\"CFBundleIdentifier\":\"$(BUNDLE_ID_PREFIX).IceCubesApp\""), formula)
    }

    /// The empty layer still builds, but the converter names the cause once, as an error
    /// on `infoLog`, so it reaches the idle error report instead of surfacing only as
    /// eleven unrelated Info.plist failures.
    func test_reportsTheMissingXcconfigAsTheCauseOfTheUndefinedSettings() throws {
        let output = try process(
            projectFile: try fixtureProject,
            xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(documentHash: try "absent".intern()))],
            folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp", files: ["App.swift"]),
                      try extensionFolder.0: try extensionFolder.1])

        // The empty-layer behaviour holds: the formula is still produced.
        XCTAssertNoThrow(try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue())

        let infoLog = try XCTUnwrap(output.outputValues[XcodeProjectConverter.infoLog])
        guard case .engine(.xcconfigMissing(let paths, let undefined))? = infoLog.errorDocument?.diagnostic else {
            return XCTFail("expected infoLog to carry the cause as an error, got \(infoLog)")
        }
        XCTAssertEqual(paths, ["input:/repo/App.xcconfig"])
        XCTAssertTrue(undefined.contains("BUNDLE_ID_PREFIX"), "\(undefined)")
    }

    /// Nothing to say about a cause that is not there: an xcconfig that is present leaves
    /// `infoLog` as the ordinary success message.
    func test_doesNotReportAMissingXcconfigWhenItIsPresent() throws {
        let output = try process(
            projectFile: try fixtureProject,
            xcconfigs: ["input:/repo/App.xcconfig": .value(try "BUNDLE_ID_PREFIX = com.example".intern())],
            folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp",
                                                                    files: ["App.swift", "Info.plist"],
                                                                    folders: ["Fonts", "Assets.xcassets"]),
                      "input:/repo/IceCubesApp/Fonts": try manifestValue("input:/repo/IceCubesApp/Fonts", files: ["Mono.ttf"]),
                      try extensionFolder.0: try extensionFolder.1])

        let infoLog = try XCTUnwrap(output.outputValues[XcodeProjectConverter.infoLog])
        guard case .value(let hash) = infoLog else {
            XCTFail("expected infoLog to carry the ordinary success message, got \(infoLog)")
            return
        }
        XCTAssertTrue(try hash.resolveAsString().contains("converted"), "should be the success message")
    }

    /// A project whose application target references nothing from its `.xcconfig`: the
    /// file being missing does not undefine anything, so it is not a broken build.
    private var fixtureProjectWithNothingReferenced: NodeValue {
        get throws {
            .value(try """
                // !$*UTF8*$!
                {
                    archiveVersion = 1;
                    objectVersion = 77;
                    objects = {
                        P1 = { isa = PBXProject; buildConfigurationList = CL1; targets = ( T1 ); };
                        CL1 = { isa = XCConfigurationList; buildConfigurations = ( C1 ); };
                        C1 = { isa = XCBuildConfiguration; name = Debug; baseConfigurationReference = XC1; buildSettings = { }; };
                        XC1 = { isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = App.xcconfig; sourceTree = "<group>"; };
                        T1 = {
                            isa = PBXNativeTarget;
                            name = App;
                            productType = "com.apple.product-type.application";
                            productReference = PR1;
                            buildConfigurationList = CL2;
                            buildPhases = ( );
                            fileSystemSynchronizedGroups = ( SG1 );
                            packageProductDependencies = ( );
                        };
                        SG1 = { isa = PBXFileSystemSynchronizedRootGroup; path = App; exceptions = ( ); sourceTree = "<group>"; };
                        PR1 = { isa = PBXFileReference; explicitFileType = wrapper.application; path = "App.app"; sourceTree = BUILT_PRODUCTS_DIR; };
                        CL2 = { isa = XCConfigurationList; buildConfigurations = ( C2 ); };
                        C2 = { isa = XCBuildConfiguration; name = Debug; buildSettings = {
                            PRODUCT_NAME = App;
                            PRODUCT_BUNDLE_IDENTIFIER = "com.example.App";
                        }; };
                    };
                    rootObject = P1;
                }
                """.intern())
        }
    }

    // MARK: - NetNewsWire's local packages (B-77)

    /// What one folder of the NetNewsWire clone holds, for the harness to answer with.
    private struct FolderContents {
        var files: [String] = []
        var folders: [String] = []
    }

    /// The converter over NetNewsWire's project file for the Mac, run the way the engine
    /// runs it: every pass's demands are answered, and it runs again, until it demands
    /// nothing new. An xcconfig is the text `xcconfigs` gives for its path, or comes from
    /// the fixture, or is not there; a folder holds what `folders` gives for its path
    /// relative to the project folder, or nothing — except `Modules`, which holds the
    /// given packages as the clone lays them out.
    private func convertNetNewsWire(modules: [String],
                                    folders folderContents: [String: FolderContents] = [:],
                                    xcconfigs xcconfigTexts: [String: String] = [:],
                                    configuration: String = "Debug",
                                    sdk: String = "macosx")
        throws -> (output: ProcessOutput, demandedFolders: [String], demandedXcconfigs: [String]) {
        let projectFolder = "input:/nnw"
        let node = try XcodeProjectConverter(thisNode: NodeRecord(id: 1, kind: XcodeProjectConverter.kind, name: nil,
                                                                  properties: ["path": "\(projectFolder)/NetNewsWire.xcodeproj",
                                                                               "sdk": sdk, "configuration": configuration],
                                                                  scheduled: false, identity: nil))
        let pbxproj = XcodeBuildSettingsTests.netNewsWire.appendingPathComponent("NetNewsWire.xcodeproj/project.pbxproj")
        var inputs: [String: [String: NodeValue]] = [
            XcodeProjectConverter.projectFile: ["\(projectFolder)/NetNewsWire.xcodeproj/project.pbxproj":
                                                    .value(try String(contentsOf: pbxproj, encoding: .utf8).intern())],
            XcodeProjectConverter.xcconfigs: [:],
            XcodeProjectConverter.folders: [:],
        ]
        for _ in 0..<10 {
            let output = try node.process(input: ProcessInput(inputValues: inputs))
            var answered = false
            for path in (output.inputWireSpecs[XcodeProjectConverter.xcconfigs] ?? [:]).keys.sorted()
            where inputs[XcodeProjectConverter.xcconfigs]?[path] == nil {
                let text: String?
                if let given = xcconfigTexts[path] {
                    text = given
                } else if path.hasPrefix(projectFolder + "/") {
                    let file = XcodeBuildSettingsTests.netNewsWire.appendingPathComponent(String(path.dropFirst(projectFolder.count + 1)))
                    text = try? String(contentsOf: file, encoding: .utf8)
                } else {
                    text = nil
                }
                inputs[XcodeProjectConverter.xcconfigs]?[path] = try text.map { .value(try $0.intern()) } ?? .noValue(reason: .initializing)
                answered = true
            }
            for path in (output.inputWireSpecs[XcodeProjectConverter.folders] ?? [:]).keys.sorted()
            where inputs[XcodeProjectConverter.folders]?[path] == nil {
                inputs[XcodeProjectConverter.folders]?[path] = .value(try netNewsWireTree(at: path, projectFolder: projectFolder,
                                                                                          modules: modules, folders: folderContents)
                                                                        .toJSON().intern())
                answered = true
            }
            guard answered else {
                return (output, (inputs[XcodeProjectConverter.folders] ?? [:]).keys.sorted(),
                        (inputs[XcodeProjectConverter.xcconfigs] ?? [:]).keys.sorted())
            }
        }
        throw XCTSkip("the converter still demanded something new after ten passes")
    }

    /// The tree of a folder of the NetNewsWire clone as `convertNetNewsWire` lays it out: a
    /// folder holds what `folders` gives for its path relative to the project folder, or
    /// nothing — except `Modules`, which holds the given packages, each holding what a
    /// package folder of the clone holds.
    private func netNewsWireTree(at path: String, projectFolder: String, modules: [String],
                                 folders folderContents: [String: FolderContents]) throws -> FolderSubtreeManifest {
        let relativePath = String(path.dropFirst(projectFolder.count + 1))
        let isPackage = relativePath.hasPrefix("Modules/") && modules.contains(String(relativePath.dropFirst("Modules/".count)))
        let given = folderContents[relativePath] ?? FolderContents()
        let files   = isPackage ? NetNewsWireModules.packageFolderFiles : given.files
        let folders = relativePath == "Modules" ? modules : isPackage ? NetNewsWireModules.packageFolderFolders : given.folders
        return FolderSubtreeManifest(entries:
            files.map { FolderSubtreeEntry(name: $0, isFolder: false, isPinned: true) }
            + (try folders.map { name in
                let subtree = try netNewsWireTree(at: "\(path)/\(name)", projectFolder: projectFolder, modules: modules, folders: folderContents)
                return FolderSubtreeEntry(name: name, isFolder: true, isPinned: true, subtree: try subtree.toJSON().intern())
            }))
    }

    /// NetNewsWire names no package for fifteen of the products its apps link: the
    /// converter looks into the synchronized `Modules` folder no target owns — its tree,
    /// which lists each folder in it too (B-135) — finds the seventeen that hold a
    /// `Package.swift`, and includes every one — so each `modules_`, `objects_`, `bundles_`
    /// and `linking_` func the formula calls is one an included formula defines, a local
    /// package's or a remote one's.
    func test_findsNetNewsWiresPackagesInItsModulesFolderAndDefinesWhatItCalls() throws {
        let modules = NetNewsWireModules.products.keys.sorted()
        let (output, demandedFolders, _) = try convertNetNewsWire(modules: modules)

        XCTAssertTrue(demandedFolders.contains("input:/nnw/Modules"))
        XCTAssertFalse(demandedFolders.contains { $0.hasPrefix("input:/nnw/Modules/") },
                       "the folders in it are read from its tree, not asked for: \(demandedFolders)")

        let formula = try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        let includedLocal = modules.filter {
            formula.contains("include funcs SwiftFormulaConverter(path: 'input:/nnw/Modules/\($0)', root: 'input:/nnw').formula")
        }
        XCTAssertEqual(includedLocal, modules, formula)

        let project = try XcodeProject(pbxproj: try Data(contentsOf: XcodeBuildSettingsTests.netNewsWire
            .appendingPathComponent("NetNewsWire.xcodeproj/project.pbxproj")))
        var remoteProducts: Set<String> = []
        for case .remote(let product, let url) in project.targets.flatMap(\.packageProducts) {
            let folder = try XCTUnwrap(XcodeFormulaEmitter.repositoryName(forURL: url))
            XCTAssertTrue(formula.contains("include funcs SwiftFormulaConverter(path: 'input:/nnw/Dependencies/\(folder)', root: 'input:/nnw').formula"),
                          "\(url)\n\(formula)")
            remoteProducts.insert(product)
        }

        let calls = try NSRegularExpression(pattern: "\\b(?:modules|objects|bundles|linking)_(\\w+)\\(\\)")
        let called = Set(calls.matches(in: formula, range: NSRange(formula.startIndex..., in: formula)).compactMap { match in
            Range(match.range(at: 1), in: formula).map { String(formula[$0]) }
        })
        XCTAssertFalse(called.isEmpty, formula)
        for product in called.sorted() {
            let vendor = NetNewsWireModules.package(vending: product, among: modules.map { "Modules/\($0)" })
            XCTAssertTrue(vendor != nil || remoteProducts.contains(product), "\(product) is called and no included package vends it")
        }
        XCTAssertTrue(called.contains("RSCoreResources") && called.contains("Account"), "\(called.sorted())")
    }

    /// With no package anywhere, the products the app links from local packages are named
    /// as the cause, not left as funcs nothing defines.
    func test_aLocalProductWithNoLocalPackageIsNamed() throws {
        let (output, _, _) = try convertNetNewsWire(modules: [])

        guard case .engine(.localPackagesNotFound(_, let products, let folders))? =
                try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).errorDocument?.diagnostic else {
            return XCTFail("expected the missing packages as the formula's error")
        }
        XCTAssertEqual(Array(products.prefix(2)), ["Account", "ActivityLog"])
        XCTAssertFalse(folders.isEmpty)
    }

    /// A missing xcconfig that nothing referenced is not a cause of anything: the build is
    /// not broken, so `infoLog` stays the ordinary success value, only noting the file by
    /// way of explanation rather than raising it as an error.
    func test_doesNotErrorWhenTheMissingXcconfigDefinesNothingReferenced() throws {
        let output = try process(
            projectFile: try fixtureProjectWithNothingReferenced,
            xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(documentHash: try "absent".intern()))],
            folders: ["input:/repo/App": try manifestValue("input:/repo/App", files: ["App.swift"])])

        XCTAssertNoThrow(try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue())

        let infoLog = try XCTUnwrap(output.outputValues[XcodeProjectConverter.infoLog])
        guard case .value(let hash) = infoLog else {
            XCTFail("a missing xcconfig nothing referenced should not be an error, got \(infoLog)")
            return
        }
        let message = try hash.resolveAsString()
        XCTAssertTrue(message.contains("input:/repo/App.xcconfig is missing"), message)
    }

    // MARK: - Plugins (B-77)

    /// An app whose folder `App` holds `schema.graphql` and `Legacy.swift`, and which runs
    /// two package plugins, as CodeEdit's app runs SwiftLint's: a target dependency on a
    /// `plugin:` product. `excludingLegacy` leaves `Legacy.swift` out of the target by an
    /// exception set.
    private func pluginProject(excludingLegacy: Bool) throws -> NodeValue {
        .value(try """
            // !$*UTF8*$!
            {
                archiveVersion = 1;
                objectVersion = 77;
                objects = {
                    P1 = { isa = PBXProject; buildConfigurationList = CL1; targets = ( T1 ); packageReferences = ( R1 ); };
                    CL1 = { isa = XCConfigurationList; buildConfigurations = ( C1 ); };
                    C1 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { }; };
                    R1 = { isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/example/Generators"; };
                    T1 = { isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application";
                           productReference = PR1; buildConfigurationList = CL2; buildPhases = ( );
                           fileSystemSynchronizedGroups = ( SG1 ); dependencies = ( TD1, TD2 ); packageProductDependencies = ( ); };
                    TD1 = { isa = PBXTargetDependency; productRef = PD1; };
                    TD2 = { isa = PBXTargetDependency; productRef = PD2; };
                    PD1 = { isa = XCSwiftPackageProductDependency; package = R1; productName = "plugin:GraphQLGenerator"; };
                    PD2 = { isa = XCSwiftPackageProductDependency; package = R1; productName = "plugin:Stamp"; };
                    SG1 = { isa = PBXFileSystemSynchronizedRootGroup; path = App; exceptions = ( \(excludingLegacy ? "EX1" : "") );
                            sourceTree = "<group>"; };
                    EX1 = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = ( Legacy.swift ); target = T1; };
                    PR1 = { isa = PBXFileReference; explicitFileType = wrapper.application; path = "App.app"; sourceTree = BUILT_PRODUCTS_DIR; };
                    CL2 = { isa = XCConfigurationList; buildConfigurations = ( C2 ); };
                    C2 = { isa = XCBuildConfiguration; name = Debug; buildSettings = {
                        PRODUCT_NAME = App;
                        PRODUCT_BUNDLE_IDENTIFIER = "com.example.App";
                    }; };
                };
                rootObject = P1;
            }
            """.intern())
    }

    /// A target whose sources only its plugins would generate has nothing to compile, as no
    /// plugin is run (B-77): the conversion fails naming the target and its plugins, rather
    /// than hand the compiler an empty folder. A Swift file the target's exceptions leave
    /// out is not its own; one they keep is, and the target compiles without its plugins.
    func test_aTargetWhoseSourcesOnlyAPluginWouldMakeFailsNamingThePlugin() throws {
        let folders = ["input:/repo/App": try manifestValue("input:/repo/App", files: ["Legacy.swift", "schema.graphql"])]

        let failed = try process(projectFile: try pluginProject(excludingLegacy: true), folders: folders)
        let document = try XCTUnwrap(try XCTUnwrap(failed.outputValues[XcodeProjectConverter.formulaOutput]).errorDocument,
                                     "expected the target and its plugins as the formula's error")
        XCTAssertEqual(document.diagnostic,
                       .engine(.sourcesOnlyFromPlugins(package: nil, target: "App", plugins: ["GraphQLGenerator", "Stamp"])))
        XCTAssertEqual(document.subject, .project(path: "input:/repo/IceCubesApp.xcodeproj"))
        XCTAssertEqual(failed.inputWireSpecs[XcodeProjectConverter.folders]?.keys.sorted(), ["input:/repo/App"],
                       "the wires are kept, so a source pushed into the folder wakes the conversion")

        let built = try process(projectFile: try pluginProject(excludingLegacy: false), folders: folders)
        let formula = try XCTUnwrap(built.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        XCTAssertTrue(formula.contains("func compiler_App() =\n    SwiftCompiler("), formula)
    }

    // MARK: - NetNewsWire's bundle (B-77)

    /// The part of the Mac folder these tests need, laid out as the clone has it: a xib
    /// with its string catalog in `MainMenu`, and the Share extension's sources, icon and
    /// localized xib in `ShareExtension`.
    private let netNewsWireMacFolder: [String: FolderContents] = [
        "Mac":                              FolderContents(files: ["AppDelegate.swift"], folders: ["MainMenu", "ShareExtension"]),
        "Mac/MainMenu":                     FolderContents(folders: ["Base.lproj", "mul.lproj"]),
        "Mac/MainMenu/Base.lproj":          FolderContents(files: ["MainMenu.xib"]),
        "Mac/MainMenu/mul.lproj":           FolderContents(files: ["MainMenu.xcstrings"]),
        "Mac/ShareExtension":               FolderContents(files: ["Info.plist", "ShareViewController.swift", "icon.icns"],
                                                           folders: ["Base.lproj"]),
        "Mac/ShareExtension/Base.lproj":    FolderContents(files: ["ShareViewController.xib"]),
    ]

    private func netNewsWireFormula(configuration: String = "Debug") throws -> String {
        let (output, _, _) = try convertNetNewsWire(modules: NetNewsWireModules.products.keys.sorted(), folders: netNewsWireMacFolder,
                                                    configuration: configuration)
        return try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
    }

    private let macResources = "NetNewsWire.app/Contents/Resources"
    private let shareResources = "NetNewsWire.app/Contents/PlugIns/NetNewsWire Share Extension.appex/Contents/Resources"

    /// A `.lproj` folder inside a synchronized folder is walked, and what it holds lands
    /// under its language folder: the main menu's xib compiled by ibtool to
    /// `Base.lproj/MainMenu.nib` in the app's module for the Mac at 15.0, and the catalog
    /// localizing it through the string catalog compiler, whose tables are placed under
    /// their languages.
    func test_aLocalizedFolderInASynchronizedFolderReachesTheBundleUnderItsLanguage() throws {
        let formula = try netNewsWireFormula()

        XCTAssertTrue(formula.contains("document: ['Base.lproj/MainMenu.xib': "
                                       + "StaticFile(path: 'input:/nnw/Mac/MainMenu/Base.lproj/MainMenu.xib').output]"), formula)
        XCTAssertTrue(formula.contains("SettingsLiteral(minimumDeploymentTarget: '15.0', module: 'NetNewsWire', targetDevices: 'mac')"), formula)
        XCTAssertFalse(formula.contains("MainMenu.xib' = StaticFile"), "compiled, not copied: \(formula)")
        XCTAssertTrue(formula.contains("catalog: ['MainMenu.xcstrings': StaticFile(path: 'input:/nnw/Mac/MainMenu/mul.lproj/MainMenu.xcstrings').output]"),
                      formula)
    }

    /// `/Localized/ShareExtension/ShareViewController.xib` is the xib in every language
    /// folder under `ShareExtension`: the app, which owns `Mac`, leaves it out, and the
    /// Share extension, which borrows it, has it under `Base.lproj` — never a path with
    /// `/Localized/` in it.
    func test_aLocalizedExceptionIsTheFileInEveryLanguageFolderOfItsFolder() throws {
        let formula = try netNewsWireFormula()

        XCTAssertFalse(formula.contains("/Localized/"), formula)
        let document = "document: ['Base.lproj/ShareViewController.xib': "
                     + "StaticFile(path: 'input:/nnw/Mac/ShareExtension/Base.lproj/ShareViewController.xib').output]"
        XCTAssertEqual(formula.components(separatedBy: document).count - 1, 1, "compiled once, for one bundle: \(formula)")
        XCTAssertTrue(formula.contains("func interface_NetNewsWire_Share_Extension_0() =\n    IBToolCompiler("), formula)
        let share = try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix("func bundle_NetNewsWire_Share_Extension()") },
                                  formula)
        XCTAssertTrue(share.contains("'Contents/Resources': TreeMerger(under: 'Contents/Resources', "
                                     + "input: ['interface0': interface_NetNewsWire_Share_Extension_0().files"), share)
        XCTAssertTrue(share.contains("'Contents/Resources/icon.icns': StaticFile(path: 'input:/nnw/Mac/ShareExtension/icon.icns').output"), share)
    }

    /// NetNewsWire's iOS Share extension borrows the app's `Resources/Assets.xcassets`
    /// through the `iOS` folder's exception set, and compiles it for itself — for the
    /// simulator, into its own bundle — as it would a catalog of its own folder (B-77 map
    /// item 15), beside the sources it borrows.
    func test_aBorrowedAssetCatalogIsCompiledForTheBorrowingTarget() throws {
        let project = try XcodeProject(pbxproj: try Data(contentsOf: XcodeBuildSettingsTests.netNewsWire
            .appendingPathComponent("NetNewsWire.xcodeproj/project.pbxproj")))
        let share = try XCTUnwrap(project.targets.first { $0.name == "NetNewsWire iOS Share Extension" })
        XCTAssertTrue(share.borrowedFiles.contains("iOS/Resources/Assets.xcassets"), "\(share.borrowedFiles)")
        let expansions = try XcodeProjectFacts.expansions(of: project.xcconfigPaths(for: share, configuration: "Debug"),
                                                          in: XcodeBuildSettingsTests.netNewsWire)
        let settings = try XcodeBuildSettings.resolve(project: project, target: share, configuration: "Debug", sdk: "iphonesimulator",
                                                      xcconfig: { expansions[$0]?.assignments }, extra: ["TARGET_NAME": share.name])
        let emitter = XcodeFormulaEmitter(project: project,
                                          build: .init(root: "input:/nnw", projectFolder: "input:/nnw", configuration: "Debug", sdk: "iphonesimulator"))

        let formula = try emitter.bundle(for: share, settings: settings, listing: { _ in nil }).products(in: "Share.appex").joined(separator: "\n\n")

        let assets = try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix("func assets_NetNewsWire_iOS_Share_Extension() =") },
                                   formula)
        XCTAssertTrue(assets.contains("catalogs: [\n        'Assets.xcassets': Folder(path: 'input:/nnw/iOS/Resources/Assets.xcassets').manifest\n        ]"),
                      assets)
        XCTAssertTrue(assets.contains("platform: 'iphonesimulator'"), assets)
        XCTAssertTrue(formula.contains("product 'Share.appex/' = TreeMerger(input: ['assets': assets_NetNewsWire_iOS_Share_Extension().files"), formula)
        XCTAssertTrue(formula.contains("'AppDefaults.swift': StaticFile(path: 'input:/nnw/iOS/AppDefaults.swift').output"), formula)
    }

    /// A part of NetNewsWire's `iOS` and `Widget` folders, laid out as the clone has them.
    private static let netNewsWireIOSFiles = [
        "iOS/AppDelegate.swift", "iOS/NetNewsWire-iOS-Bridging-Header.h",
        "iOS/UIKit Extensions/SFSafariViewController+Extras.h", "iOS/UIKit Extensions/SFSafariViewController+Extras.m",
        "iOS/Base.lproj/Main.storyboard", "iOS/Base.lproj/LaunchScreenPhone.storyboard",
        "iOS/Settings/Settings.storyboard", "iOS/Resources/Info.plist", "iOS/Resources/page.html",
        "iOS/ShareExtension/Info.plist", "iOS/ShareExtension/ShareViewController.swift",
        "iOS/ShareExtension/ShareFolderPickerAccountCell.xib",
        "Widget/WidgetBundle.swift", "Widget/Info.plist", "Widget/NetNewsWire_iOS_WidgetExtension.entitlements",
        "Widget/Resources/widget-sample.json",
        "Shared/Resources/GlobalKeyboardShortcuts.plist", "Shared/Widget/WidgetData.swift",
    ]

    /// A simulator build of NetNewsWire is its iOS app — the application whose `SDKROOT`
    /// is `iphoneos` — with the two extensions it embeds, the Share extension and the
    /// widget, each under the app's `PlugIns/` in the flat iOS layout, for
    /// `arm64-apple-ios17.0-simulator`; its storyboards compiled by ibtool, its Objective-C
    /// by clang. Nothing of the Mac app's is built — not its folder, its extensions or
    /// Sparkle's framework; the `Mac` folder is only looked into for local packages, as
    /// every synchronized folder is.
    func test_aSimulatorBuildOfNetNewsWireIsItsIOSAppWithItsExtensions() throws {
        let (output, demandedFolders, demandedXcconfigs) = try convertNetNewsWire(
            modules: NetNewsWireModules.products.keys.sorted(),
            folders: Self.folderContents(of: Self.netNewsWireIOSFiles),
            sdk: "iphonesimulator")
        let formula = try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        let info = try XCTUnwrap(output.outputValues[XcodeProjectConverter.infoLog]).expectValue().resolveAsString()

        XCTAssertTrue(info.hasPrefix("converted NetNewsWire-iOS for iphonesimulator, Debug"), info)
        XCTAssertTrue(formula.contains("product 'NetNewsWire.app/NetNewsWire' ="), formula)
        XCTAssertTrue(formula.contains("product 'NetNewsWire.app/PlugIns/NetNewsWire iOS Share Extension.appex/NetNewsWire iOS Share Extension' ="),
                      formula)
        XCTAssertTrue(formula.contains("product 'NetNewsWire.app/PlugIns/NetNewsWire iOS Widget Extension.appex/NetNewsWire iOS Widget Extension' ="),
                      formula)
        XCTAssertTrue(formula.contains("target: 'arm64-apple-ios17.0-simulator'"), formula)
        XCTAssertTrue(formula.contains("document: ['Base.lproj/Main.storyboard': StaticFile(path: 'input:/nnw/iOS/Base.lproj/Main.storyboard').output]"),
                      formula)
        XCTAssertTrue(formula.contains("'input:/nnw/iOS/UIKit Extensions/SFSafariViewController+Extras.m'"), formula)
        XCTAssertTrue(formula.contains("bridgingHeader: ['iOS/NetNewsWire-iOS-Bridging-Header.h'"), formula)
        XCTAssertTrue(formula.contains("product 'NetNewsWire.app/PlugIns/NetNewsWire iOS Widget Extension.appex/widget-sample.json' ="),
                      formula)
        XCTAssertFalse(formula.contains("CodeSigner("), "the simulator's bundle is unsigned: \(formula)")

        for macThing in ["Subscribe to Feed", "input:/nnw/Mac", "NetNewsWire Share Extension.appex", "frameworks_Sparkle"] {
            XCTAssertFalse(formula.contains(macThing), "\(macThing): \(formula)")
        }
        XCTAssertTrue(demandedFolders.contains("input:/nnw/Widget"), "\(demandedFolders)")
        XCTAssertTrue(demandedXcconfigs.contains("input:/nnw/xcconfig/NetNewsWire_iOSwidgetextension_target.xcconfig"), "\(demandedXcconfigs)")
    }

    /// NetNewsWire's Mac app compiles `Mac/NSOpenPanel+Extras.m` through clang with ARC,
    /// modules, the project's C standard and the Debug definitions, over the `Mac` folder
    /// as its header folder, and links it into the executable; its Swift imports the
    /// bridging header the settings name, `Mac/NetNewsWire-Bridging-Header.h`, with the
    /// app's other headers beside it. The extensions' own folders hold no Objective-C, so
    /// theirs is Swift alone.
    func test_theMacAppsObjectiveCIsCompiledAndItsBridgingHeaderImported() throws {
        var folders = netNewsWireMacFolder
        folders["Mac"]?.files += ["NSOpenPanel+Extras.h", "NSOpenPanel+Extras.m", "NetNewsWire-Bridging-Header.h", "WKPreferencesPrivate.h"]
        let (output, _, _) = try convertNetNewsWire(modules: NetNewsWireModules.products.keys.sorted(), folders: folders)
        let formula = try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()

        XCTAssertTrue(formula.contains("func preprocess_NetNewsWire(path) =\n    ClangPreprocessor("), formula)
        XCTAssertTrue(formula.contains("SettingsLiteral(cStandard: 'gnu11', cxxStandard: 'gnu++14', defines: 'DEBUG=1,SKIP_APP_GROUP_ACCESS=1', "
                                       + "modules: 'true', objectiveCARC: 'true', target: 'arm64-apple-macosx15.0')"), formula)
        XCTAssertTrue(formula.contains("'input:/nnw/Mac': Folder(path: 'input:/nnw/Mac').manifest"), formula)
        XCTAssertTrue(formula.contains("'input:/nnw/Mac/NSOpenPanel+Extras.m.o': ClangCompiler("), formula)
        XCTAssertTrue(formula.contains(",\n        bridgingHeader: ['Mac/NetNewsWire-Bridging-Header.h': "
                                       + "StaticFile(path: 'input:/nnw/Mac/NetNewsWire-Bridging-Header.h').output],\n"
                                       + "        headerTrees: ['NetNewsWire': headers_NetNewsWire().files]"), formula)
        XCTAssertTrue(formula.contains("'Mac/NSOpenPanel+Extras.h': StaticFile(path: 'input:/nnw/Mac/NSOpenPanel+Extras.h').output"), formula)
        XCTAssertTrue(formula.contains("'Mac/WKPreferencesPrivate.h': StaticFile(path: 'input:/nnw/Mac/WKPreferencesPrivate.h').output"), formula)
        XCTAssertTrue(formula.contains("-Xcc,-DDEBUG=1,-Xcc,-DSKIP_APP_GROUP_ACCESS=1"), formula)
        XCTAssertEqual(formula.components(separatedBy: "ClangPreprocessor(").count - 1, 1, "the app's alone: \(formula)")
    }

    /// The eight themes are folder references in the app's resources phase, though the
    /// app owns synchronized folders: each is copied whole, under its own name, into the
    /// bundle's resources.
    func test_aFolderReferenceInTheResourcesPhaseIsCopiedWhole() throws {
        let formula = try netNewsWireFormula()

        for theme in ["Appanoose", "Biblioteca", "Hyperlegible", "NewsFax", "Promenade", "Sepia", "Tiqoe Dark", "Verdana Revival"] {
            XCTAssertTrue(formula.contains("FolderTreeBuilder(under: '\(theme).nnwtheme', "
                                           + "folder: ['folder': Folder(path: 'input:/nnw/Themes/\(theme).nnwtheme').manifest]).files"),
                          "\(theme)\n\(formula)")
        }
        XCTAssertFalse(formula.contains("'Contents/Resources/Sepia.nnwtheme'"), formula)
    }

    /// Every file of the clone's `Mac` and `Shared` folders at the pinned commit that is
    /// not Swift, as the clone lays them out, with a Swift file where an exception names
    /// one — and so every file the bundles' resources are made from.
    private static let netNewsWireMacAndSharedFiles = [
        "Mac/AppDelegate.swift", "Mac/NSOpenPanel+Extras.h", "Mac/NSOpenPanel+Extras.m", "Mac/NetNewsWire-Bridging-Header.h",
        "Mac/WKPreferencesPrivate.h", "Mac/About/AboutWindowController.xib",
        "Mac/MainMenu/Base.lproj/MainMenu.xib", "Mac/MainMenu/mul.lproj/MainMenu.xcstrings",
        "Mac/MainWindow/Base.lproj/MainWindow.xib", "Mac/MainWindow/Detail/blank.html", "Mac/MainWindow/Detail/main_mac.js",
        "Mac/MainWindow/Detail/page.html",
        "Mac/Resources/Credits.rtf", "Mac/Resources/Info.plist", "Mac/Resources/KeyboardShortcuts/KeyboardShortcuts.html",
        "Mac/Resources/NetNewsWire-dev.entitlements", "Mac/Resources/NetNewsWire.entitlements",
        "Mac/Resources/NetNewsWire.provisionprofile", "Mac/Resources/NetNewsWire.sdef", "Mac/Resources/container-migration.plist",
        "Mac/SafariExtension/Info.plist", "Mac/SafariExtension/SafariExtensionHandler.swift",
        "Mac/SafariExtension/Subscribe_to_Feed.entitlements", "Mac/SafariExtension/ToolbarItemIcon.pdf",
        "Mac/ShareExtension/Base.lproj/ShareViewController.xib", "Mac/ShareExtension/Info.plist",
        "Mac/ShareExtension/ShareExtension.entitlements", "Mac/ShareExtension/ShareViewController.swift", "Mac/ShareExtension/icon.icns",
        "Shared/Article Rendering/ArticleRenderer.swift", "Shared/Article Rendering/core.css", "Shared/Article Rendering/main.js",
        "Shared/Article Rendering/newsfoot.js", "Shared/Article Rendering/stylesheet.css", "Shared/Article Rendering/template.html",
        "Shared/DefaultAccountNames.xcstrings", "Shared/Localizable.xcstrings", "Shared/Importers/DefaultFeeds.opml",
        "Shared/Resources/ContentRules.json", "Shared/Resources/DetailKeyboardShortcuts.plist",
        "Shared/Resources/GlobalKeyboardShortcuts.plist", "Shared/Resources/SidebarKeyboardShortcuts.plist",
        "Shared/Resources/TimelineKeyboardShortcuts.plist", "Shared/ShareExtension/SafariExt.js",
        "Shared/ShareExtension/ShareDefaultContainer.swift", "Shared/Widget/WidgetData.swift",
    ]

    /// Those files as the folders the converter walks, each with what is directly in it.
    private static func folderContents(of files: [String]) -> [String: FolderContents] {
        var contents: [String: FolderContents] = [:]
        for file in files {
            var components = file.split(separator: "/").map(String.init)
            let name = components.removeLast()
            contents[components.joined(separator: "/"), default: FolderContents()].files.append(name)
            while components.count > 1 {
                let child = components.removeLast()
                let parent = components.joined(separator: "/")
                if contents[parent]?.folders.contains(child) != true {
                    contents[parent, default: FolderContents()].folders.append(child)
                }
            }
        }
        return contents
    }

    /// The files each Mac bundle copies from the synchronized folders are the ones Xcode
    /// 26.6 copied into the bundles it built from the same commit, flattened as it put
    /// them: the four keyboard shortcut plists NetNewsWire reads at launch, the container
    /// migration plist, the article view's HTML, CSS and JavaScript, the scripting
    /// dictionary, the credits, the default feeds; not the targets' Info.plists or
    /// provisioning profile, which exceptions leave out, nor an entitlements file, nor a
    /// header. The Share extension gets its icon and the JavaScript it borrows from
    /// `Shared`, the Safari extension its toolbar icon.
    func test_eachMacBundleCopiesWhatXcodeCopiesFromItsSynchronizedFolders() throws {
        let (output, _, _) = try convertNetNewsWire(modules: NetNewsWireModules.products.keys.sorted(),
                                                    folders: Self.folderContents(of: Self.netNewsWireMacAndSharedFiles))
        let formula = try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        func copied(into target: String) throws -> Set<String> {
            let bundle = try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix("func bundle_\(target)() =") }, formula)
            let expression = try NSRegularExpression(pattern: "'Contents/Resources/([^']+)': StaticFile")
            return Set(expression.matches(in: bundle, range: NSRange(bundle.startIndex..., in: bundle)).compactMap {
                Range($0.range(at: 1), in: bundle).map { String(bundle[$0]) }
            })
        }

        XCTAssertEqual(try copied(into: "NetNewsWire"), [
            "ContentRules.json", "Credits.rtf", "DefaultFeeds.opml", "DetailKeyboardShortcuts.plist", "GlobalKeyboardShortcuts.plist",
            "KeyboardShortcuts.html", "NetNewsWire.sdef", "SidebarKeyboardShortcuts.plist", "TimelineKeyboardShortcuts.plist",
            "blank.html", "container-migration.plist", "core.css", "main.js", "main_mac.js", "newsfoot.js", "page.html",
            "stylesheet.css", "template.html",
        ])
        XCTAssertEqual(try copied(into: "NetNewsWire_Share_Extension"), ["SafariExt.js", "icon.icns"])
        XCTAssertEqual(try copied(into: "Subscribe_to_Feed"), ["ToolbarItemIcon.pdf"])
        XCTAssertTrue(formula.contains("'Contents/Resources/GlobalKeyboardShortcuts.plist': "
                                       + "StaticFile(path: 'input:/nnw/Shared/Resources/GlobalKeyboardShortcuts.plist').output"), formula)
    }

    /// Every setting the Mac plists name reaches the builder: run over the project's own
    /// plists with what the formula hands it, none is undefined, and the values are the
    /// evaluated ones — the signing team's prefix empty, as no team signs.
    func test_theInfoPlistBuilderIsHandedEverySettingThePlistsName() throws {
        let formula = try netNewsWireFormula()
        let bundles = [("NetNewsWire", "Mac/Resources/Info.plist"),
                       ("NetNewsWire_Share_Extension", "Mac/ShareExtension/Info.plist"),
                       ("Subscribe_to_Feed", "Mac/SafariExtension/Info.plist")]
        var plists: [String: [String: Any]] = [:]
        for (target, basePath) in bundles {
            plists[basePath] = try buildInfoPlist(target: target, formula: formula, base: basePath)
        }

        let app = try XCTUnwrap(plists["Mac/Resources/Info.plist"])
        XCTAssertEqual(app["OrganizationIdentifier"] as? String, "com.ranchero")
        XCTAssertEqual(app["AppGroup"] as? String, "group.com.ranchero.NetNewsWire-Evergreen-DEBUG")
        XCTAssertEqual(app["AppIdentifierPrefix"] as? String, "")
        XCTAssertEqual(app["DeveloperEntitlements"] as? String, "")
        XCTAssertNil(app["PRODUCT_NAME"], "a build setting is a variable, not an entry")
        XCTAssertEqual(try XCTUnwrap(plists["Mac/ShareExtension/Info.plist"])["AppGroup"] as? String, "group.com.ranchero.NetNewsWire-Evergreen")
    }

    /// Every Mac bundle is signed with the entitlements its target's settings name, each
    /// `$(VAR)` in them resolved: the app group the plists name, the Sparkle names under
    /// the bundle identifier, and the signing team's prefix empty, as no team signs.
    func test_eachMacBundleIsSignedWithItsEntitlementsResolved() throws {
        let formula = try netNewsWireFormula()
        let signers = [("NetNewsWire", "Mac/Resources/NetNewsWire.entitlements"),
                       ("NetNewsWire_Share_Extension", "Mac/ShareExtension/ShareExtension.entitlements"),
                       ("Subscribe_to_Feed", "Mac/SafariExtension/Subscribe_to_Feed.entitlements")]
        var entitlements: [String: [String: Any]] = [:]
        for (target, path) in signers {
            let signer = try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.contains("func signed_\(target)() =\n") }, formula)
            let pattern = "entitlements: \\['entitlements': InfoPlistBuilder\\(\\n *buildSettings: '([^']*)',\\n"
                        + " *base: \\['base': StaticFile\\(path: '([^']*)'\\)"
            let match = try XCTUnwrap(try NSRegularExpression(pattern: pattern).firstMatch(in: signer, range: NSRange(signer.startIndex..., in: signer)),
                                      "no entitlements for \(target): \(signer)")
            XCTAssertEqual(String(signer[try XCTUnwrap(Range(match.range(at: 2), in: signer))]), "input:/nnw/\(path)")
            let settings = String(signer[try XCTUnwrap(Range(match.range(at: 1), in: signer))])
            entitlements[target] = try buildPlist(keys: nil, settings: settings, base: path)
        }

        let app = try XCTUnwrap(entitlements["NetNewsWire"])
        XCTAssertEqual(app["com.apple.security.application-groups"] as? [String], ["group.com.ranchero.NetNewsWire-Evergreen-DEBUG"])
        XCTAssertEqual(app["com.apple.security.temporary-exception.mach-lookup.global-name"] as? [String],
                       ["com.ranchero.NetNewsWire-Evergreen-DEBUG-spks", "com.ranchero.NetNewsWire-Evergreen-DEBUG-spki"])
        XCTAssertEqual(app["com.apple.developer.ubiquity-kvstore-identifier"] as? String, "com.ranchero.NetNewsWire")
        XCTAssertEqual(try XCTUnwrap(entitlements["NetNewsWire_Share_Extension"])["com.apple.security.application-groups"] as? [String],
                       ["group.com.ranchero.NetNewsWire-Evergreen-DEBUG"], "the app's group, which the extension shares")
    }

    // MARK: - NetNewsWire's Swift settings, PkgInfo and hardened runtime (B-77)

    /// The literal a target's Swift compiler is configured with.
    private func swiftCompilerLiteral(of target: String, in formula: String) throws -> String {
        let compiler = try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix("func compiler_\(target)() =") }, formula)
        let literal = try XCTUnwrap(compiler.range(of: "SettingsLiteral("), compiler)
        return String(compiler[literal.lowerBound...].prefix { $0 != "\n" })
    }

    /// Debug's Swift settings reach the app's and each extension's compiler as Xcode 26.6
    /// passed them at the pinned commit (`xcodebuild build`, its `swiftc` lines): the
    /// compilation conditions as `-D`s; `OTHER_SWIFT_FLAGS` as the debug file writes them,
    /// having replaced the project file's upcoming features without `$(inherited)`;
    /// `DebugDescriptionMacro`, on by Xcode's default; and `-warnings-as-errors` from
    /// `SWIFT_TREAT_WARNINGS_AS_ERRORS`. Swift 6 is the language mode, so no feature Swift 6
    /// already has is passed. `xcodebuild -showBuildSettings` for the three targets gives
    /// the same `OTHER_SWIFT_FLAGS`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG
    /// SKIP_APP_GROUP_ACCESS` and `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`, and no
    /// `SWIFT_STRICT_CONCURRENCY` or `SWIFT_UPCOMING_FEATURE_*`.
    func test_theMacTargetsSwiftSettingsReachTheirCompilersAsXcodePassesThem() throws {
        let formula = try netNewsWireFormula()
        let flags = "unsafeFlags: '[\"-DDEBUG\",\"-DSKIP_APP_GROUP_ACCESS\",\"-Xfrontend\",\"-warn-long-function-bodies=800\","
                  + "\"-Xfrontend\",\"-warn-long-expression-type-checking=1000\",\"-warnings-as-errors\"]'"

        for target in ["NetNewsWire", "NetNewsWire_Share_Extension", "Subscribe_to_Feed"] {
            let literal = try swiftCompilerLiteral(of: target, in: formula)
            XCTAssertTrue(literal.contains("defines: 'DEBUG,SKIP_APP_GROUP_ACCESS'"), literal)
            XCTAssertTrue(literal.contains("experimentalFeatures: 'DebugDescriptionMacro'"), literal)
            XCTAssertTrue(literal.contains(flags), literal)
            XCTAssertFalse(literal.contains("upcomingFeatures"), literal)
            XCTAssertTrue(literal.contains("languageMode: '6'"), literal)
        }
        XCTAssertTrue(try swiftCompilerLiteral(of: "Subscribe_to_Feed", in: formula).contains("arguments: '-application-extension'"))
    }

    /// Release replaces `OTHER_SWIFT_FLAGS` with `-DRELEASE` and sets no compilation
    /// condition, as `xcodebuild -showBuildSettings -configuration Release` says.
    func test_releasesSwiftSettingsAreItsOwn() throws {
        let literal = try swiftCompilerLiteral(of: "NetNewsWire", in: try netNewsWireFormula(configuration: "Release"))

        XCTAssertTrue(literal.contains("unsafeFlags: '[\"-DRELEASE\",\"-warnings-as-errors\"]'"), literal)
        XCTAssertFalse(literal.contains("defines:"), literal)
    }

    /// The app's bundle has a `PkgInfo` beside its plist, from the plist as built —
    /// `APPL????`, what Xcode 26.6 wrote for the same commit — and neither extension has
    /// one, as neither of Xcode's has.
    func test_theAppHasAPkgInfoFromItsPlistAndTheExtensionsNone() throws {
        let formula = try netNewsWireFormula()

        let app = try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix("func bundle_NetNewsWire() =") }, formula)
        XCTAssertTrue(app.contains("        'Contents/PkgInfo': infoPlist_NetNewsWire().pkgInfo"), app)
        XCTAssertEqual(try buildInfoPlistOutputs(target: "NetNewsWire", formula: formula, base: "Mac/Resources/Info.plist").pkgInfo, "APPL????")
        for target in ["NetNewsWire_Share_Extension", "Subscribe_to_Feed"] {
            let bundle = try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix("func bundle_\(target)() =") }, formula)
            XCTAssertFalse(bundle.contains("PkgInfo"), bundle)
        }
    }

    /// `ENABLE_HARDENED_RUNTIME`: Debug leaves it off for the app and the Mac extensions'
    /// common file turns it on for both extensions; Release turns it on for all three —
    /// `xcodebuild -showBuildSettings` says the same of each — and each signer is told so.
    func test_theHardenedRuntimeIsSignedWhereTheSettingsAskForIt() throws {
        func signer(_ target: String, _ formula: String) throws -> String {
            try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.contains("func signed_\(target)() =\n") }, formula)
        }
        let debug = try netNewsWireFormula()
        let release = try netNewsWireFormula(configuration: "Release")

        let hardened = "SettingsLiteral(hardenedRuntime: 'true', identity: '-')"
        XCTAssertFalse(try signer("NetNewsWire", debug).contains("hardenedRuntime"))
        for target in ["NetNewsWire_Share_Extension", "Subscribe_to_Feed"] {
            let debugSigner = try signer(target, debug)
            XCTAssertTrue(debugSigner.contains(hardened), debugSigner)
        }
        for target in ["NetNewsWire", "NetNewsWire_Share_Extension", "Subscribe_to_Feed"] {
            let releaseSigner = try signer(target, release)
            XCTAssertTrue(releaseSigner.contains(hardened), releaseSigner)
        }
    }

    /// The plist the formula's `InfoPlistBuilder` for a target's `Contents/Info.plist`
    /// builds over the fixture's copy of the project's plist, failing the test if it
    /// reports anything undefined.
    private func buildInfoPlist(target: String, formula: String, base: String) throws -> [String: Any] {
        try buildInfoPlistOutputs(target: target, formula: formula, base: base).plist
    }

    /// The same builder's outputs: the plist, and the `PkgInfo` from it.
    private func buildInfoPlistOutputs(target: String, formula: String, base: String) throws -> (plist: [String: Any], pkgInfo: String) {
        let bundle = try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix("func bundle_\(target)() =") }, formula)
        XCTAssertTrue(bundle.contains("'Contents/Info.plist': infoPlist_\(target)().plist"), bundle)
        let builder = try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix("func infoPlist_\(target)() =") }, formula)
        let pattern = "InfoPlistBuilder\\(\\n *keys: '([^']*)',\\n *buildSettings: '([^']*)',"
        let match = try XCTUnwrap(try NSRegularExpression(pattern: pattern).firstMatch(in: builder, range: NSRange(builder.startIndex..., in: builder)),
                                  "no InfoPlistBuilder for \(target)")
        let keys = String(builder[try XCTUnwrap(Range(match.range(at: 1), in: builder))])
        let settings = String(builder[try XCTUnwrap(Range(match.range(at: 2), in: builder))])
        return try buildPlistOutputs(keys: keys, settings: settings, base: base)
    }

    /// The plist an `InfoPlistBuilder` with these properties builds over the fixture's
    /// copy of the file at `base`.
    private func buildPlist(keys: String?, settings: String, base: String) throws -> [String: Any] {
        try buildPlistOutputs(keys: keys, settings: settings, base: base).plist
    }

    private func buildPlistOutputs(keys: String?, settings: String, base: String) throws -> (plist: [String: Any], pkgInfo: String) {
        var properties = [InfoPlistBuilder.buildSettingsProperty: settings]
        properties[InfoPlistBuilder.keysProperty] = keys
        let node = try InfoPlistBuilder(thisNode: NodeRecord(id: 1, kind: InfoPlistBuilder.kind, name: nil,
                                                             properties: properties,
                                                             scheduled: false, identity: nil))
        let baseBytes = try Data(contentsOf: XcodeBuildSettingsTests.netNewsWire.appendingPathComponent(base))
        let output = try node.process(input: ProcessInput(inputValues: [InfoPlistBuilder.base: ["base": .value(try [UInt8](baseBytes).intern())]]))
        let plist = try XCTUnwrap(output.outputValues[InfoPlistBuilder.output])
        guard case .value(let hash) = plist else {
            if case .noValue(.error(let messageHash)) = plist {
                XCTFail("\(base): \(try messageHash.resolveAsString())")
            }
            return ([:], "")
        }
        let bytes = try XCTUnwrap(try DataObjectStore.shared.read(hash: hash))
        let pkgInfo = try XCTUnwrap(output.outputValues[InfoPlistBuilder.pkgInfo]).expectValue().resolveAsString()
        return (try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any]), pkgInfo)
    }

    /// NetNewsWire's `#include?` of a developer's own settings resolves inside `input:`
    /// when the clone is pushed under a base above it. A clone without the file converts
    /// without an error, and the port tolerates the absent value, so the idle report does
    /// not name it; the file stays demanded, so pushing it later is seen — its
    /// `ORGANIZATION_IDENTIFIER` then reaches the bundle identifier.
    func test_anOptionalIncludeNobodyPushedIsNotAnErrorAndAPushOfItIsSeen() throws {
        let developerSettings = "input:/SharedXcodeSettings/DeveloperSettings.xcconfig"
        let (absent, _, demanded) = try convertNetNewsWire(modules: NetNewsWireModules.products.keys.sorted(), folders: netNewsWireMacFolder)

        XCTAssertTrue(demanded.contains(developerSettings), "\(demanded)")
        XCTAssertNotNil(absent.inputWireSpecs[XcodeProjectConverter.xcconfigs]?[developerSettings], "still demanded once known absent")
        XCTAssertTrue(XcodeProjectConverter.descriptor.toleratesAbsentValue(onInputPort: XcodeProjectConverter.xcconfigs))
        guard case .value = try XCTUnwrap(absent.outputValues[XcodeProjectConverter.infoLog]) else {
            XCTFail("an optional include nobody pushed is not an error: \(String(describing: absent.outputValues[XcodeProjectConverter.infoLog]))")
            return
        }
        let absentFormula = try XCTUnwrap(absent.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        XCTAssertTrue(absentFormula.contains("\"PRODUCT_BUNDLE_IDENTIFIER\":\"com.ranchero.NetNewsWire-Evergreen-DEBUG\""), absentFormula)

        let (present, _, _) = try convertNetNewsWire(modules: NetNewsWireModules.products.keys.sorted(), folders: netNewsWireMacFolder,
                                                     xcconfigs: [developerSettings: "ORGANIZATION_IDENTIFIER = org.example"])
        let presentFormula = try XCTUnwrap(present.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        XCTAssertTrue(presentFormula.contains("\"PRODUCT_BUNDLE_IDENTIFIER\":\"org.example.NetNewsWire-Evergreen-DEBUG\""), presentFormula)
    }
}
