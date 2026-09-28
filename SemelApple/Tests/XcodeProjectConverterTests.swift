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

    /// `folders` as given, with the unowned folder holding a source and no package unless
    /// the test says otherwise: a test about something else still has it answered.
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
                                                     XcodeProjectConverter.folders: folders]
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
                       ["input:/repo/IceCubesApp": "Folder(path: 'input:/repo/IceCubesApp').manifest",
                        "input:/repo/IceCubesShareExtension": "Folder(path: 'input:/repo/IceCubesShareExtension').manifest",
                        "input:/repo/IceCubesNotifications": "Folder(path: 'input:/repo/IceCubesNotifications').manifest"],
                       "the embedded extension's folder is walked too, and the folder no target owns is looked into")
        XCTAssertTrue(isPending(output))
    }

    private var extensionFolder: (String, NodeValue) {
        get throws { ("input:/repo/IceCubesShareExtension", try manifestValue("input:/repo/IceCubesShareExtension", files: ["Share.swift"])) }
    }

    /// The folder is walked one level per pass, like every folder walk, except into a
    /// catalog, which its own compiler walks.
    func test_walksSubfoldersButNotCatalogs() throws {
        let output = try process(projectFile: try fixtureProject,
                                 xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(messageDataObjectHash: try "absent".intern()))],
                                 folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp",
                                                                                         files: ["App.swift"],
                                                                                         folders: ["Views", "Assets.xcassets"])])

        XCTAssertEqual(output.inputWireSpecs[XcodeProjectConverter.folders]?.keys.sorted(),
                       ["input:/repo/IceCubesApp", "input:/repo/IceCubesApp/Views", "input:/repo/IceCubesNotifications",
                        "input:/repo/IceCubesShareExtension"])
        XCTAssertTrue(isPending(output))
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

        guard case .noValue(.error(let messageHash)) = try XCTUnwrap(output.outputValues[XcodeProjectConverter.infoLog]) else {
            XCTFail("expected the missing include on infoLog as an error")
            return
        }
        let message = try messageHash.resolveAsString()
        XCTAssertTrue(message.contains("input:/repo/Base.xcconfig is missing") && message.contains("BUNDLE_ID_PREFIX"), message)
    }

    /// The xcconfig a fresh clone lacks is an empty layer, not a stall: the formula is
    /// emitted with the reference unresolved for the plist builder to report.
    func test_aMissingXcconfigDoesNotStallTheConversion() throws {
        let output = try process(
            projectFile: try fixtureProject,
            xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(messageDataObjectHash: try "absent".intern()))],
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
            xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(messageDataObjectHash: try "absent".intern()))],
            folders: ["input:/repo/IceCubesApp": try manifestValue("input:/repo/IceCubesApp", files: ["App.swift"]),
                      try extensionFolder.0: try extensionFolder.1])

        // The empty-layer behaviour holds: the formula is still produced.
        XCTAssertNoThrow(try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue())

        let infoLog = try XCTUnwrap(output.outputValues[XcodeProjectConverter.infoLog])
        guard case .noValue(.error(let messageHash)) = infoLog else {
            XCTFail("expected infoLog to carry the cause as an error, got \(infoLog)")
            return
        }
        let message = try messageHash.resolveAsString()
        XCTAssertTrue(message.contains("input:/repo/App.xcconfig is missing"), message)
        XCTAssertTrue(message.contains("BUNDLE_ID_PREFIX"), message)
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
                                    xcconfigs xcconfigTexts: [String: String] = [:])
        throws -> (output: ProcessOutput, demandedFolders: [String], demandedXcconfigs: [String]) {
        let projectFolder = "input:/nnw"
        let node = try XcodeProjectConverter(thisNode: NodeRecord(id: 1, kind: XcodeProjectConverter.kind, name: nil,
                                                                  properties: ["path": "\(projectFolder)/NetNewsWire.xcodeproj",
                                                                               "sdk": "macosx"],
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
                let relativePath = String(path.dropFirst(projectFolder.count + 1))
                let isPackage = relativePath.hasPrefix("Modules/") && modules.contains(String(relativePath.dropFirst("Modules/".count)))
                let given = folderContents[relativePath] ?? FolderContents()
                inputs[XcodeProjectConverter.folders]?[path] = try manifestValue(
                    path,
                    files:   isPackage ? NetNewsWireModules.packageFolderFiles : given.files,
                    folders: relativePath == "Modules" ? modules : isPackage ? NetNewsWireModules.packageFolderFolders : given.folders)
                answered = true
            }
            guard answered else {
                return (output, (inputs[XcodeProjectConverter.folders] ?? [:]).keys.sorted(),
                        (inputs[XcodeProjectConverter.xcconfigs] ?? [:]).keys.sorted())
            }
        }
        throw XCTSkip("the converter still demanded something new after ten passes")
    }

    /// NetNewsWire names no package for fifteen of the products its apps link: the
    /// converter looks into the synchronized `Modules` folder no target owns, and a level
    /// later into each folder in it, finds the seventeen that hold a `Package.swift`, and
    /// includes every one — so each `modules_`, `objects_` and `bundles_` func the formula
    /// calls is one an included formula defines, a local package's or a remote one's.
    func test_findsNetNewsWiresPackagesInItsModulesFolderAndDefinesWhatItCalls() throws {
        let modules = NetNewsWireModules.products.keys.sorted()
        let (output, demandedFolders, _) = try convertNetNewsWire(modules: modules)

        XCTAssertTrue(demandedFolders.contains("input:/nnw/Modules"))
        for name in modules {
            XCTAssertTrue(demandedFolders.contains("input:/nnw/Modules/\(name)"), name)
        }
        XCTAssertFalse(demandedFolders.contains("input:/nnw/Modules/Account/Sources"), "a package's own folders are its converter's")

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

        let calls = try NSRegularExpression(pattern: "\\b(?:modules|objects|bundles)_(\\w+)\\(\\)")
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

        guard case .noValue(.error(let messageHash)) = try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]) else {
            XCTFail("expected the missing packages as the formula's error")
            return
        }
        let message = try messageHash.resolveAsString()
        XCTAssertTrue(message.contains("links Account, ActivityLog,") && message.contains("Modules"), message)
    }

    /// A missing xcconfig that nothing referenced is not a cause of anything: the build is
    /// not broken, so `infoLog` stays the ordinary success value, only noting the file by
    /// way of explanation rather than raising it as an error.
    func test_doesNotErrorWhenTheMissingXcconfigDefinesNothingReferenced() throws {
        let output = try process(
            projectFile: try fixtureProjectWithNothingReferenced,
            xcconfigs: ["input:/repo/App.xcconfig": .noValue(reason: .error(messageDataObjectHash: try "absent".intern()))],
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

    private func netNewsWireFormula() throws -> String {
        let (output, _, _) = try convertNetNewsWire(modules: NetNewsWireModules.products.keys.sorted(), folders: netNewsWireMacFolder)
        return try XCTUnwrap(output.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
    }

    private let macResources = "NetNewsWire.app/Contents/Resources"
    private let shareResources = "NetNewsWire.app/Contents/PlugIns/NetNewsWire Share Extension.appex/Contents/Resources"

    /// A `.lproj` folder inside a synchronized folder is walked, and what it holds lands
    /// under its language folder: the main menu's xib at `Base.lproj/MainMenu.xib` —
    /// copied, not yet compiled — and the catalog localizing it through the string catalog
    /// compiler, whose tables are placed under their languages.
    func test_aLocalizedFolderInASynchronizedFolderReachesTheBundleUnderItsLanguage() throws {
        let formula = try netNewsWireFormula()

        XCTAssertTrue(formula.contains("product '\(macResources)/Base.lproj/MainMenu.xib' = "
                                       + "StaticFile(path: 'input:/nnw/Mac/MainMenu/Base.lproj/MainMenu.xib').output"), formula)
        XCTAssertTrue(formula.contains("catalog: ['MainMenu.xcstrings': StaticFile(path: 'input:/nnw/Mac/MainMenu/mul.lproj/MainMenu.xcstrings').output]"),
                      formula)
        XCTAssertFalse(formula.contains("product '\(macResources)/MainMenu.xib'"), "not flattened: \(formula)")
    }

    /// `/Localized/ShareExtension/ShareViewController.xib` is the xib in every language
    /// folder under `ShareExtension`: the app, which owns `Mac`, leaves it out, and the
    /// Share extension, which borrows it, has it under `Base.lproj` — never a path with
    /// `/Localized/` in it.
    func test_aLocalizedExceptionIsTheFileInEveryLanguageFolderOfItsFolder() throws {
        let formula = try netNewsWireFormula()

        XCTAssertFalse(formula.contains("/Localized/"), formula)
        XCTAssertFalse(formula.contains("product '\(macResources)/Base.lproj/ShareViewController.xib'"), formula)
        XCTAssertTrue(formula.contains("product '\(shareResources)/Base.lproj/ShareViewController.xib' = "
                                       + "StaticFile(path: 'input:/nnw/Mac/ShareExtension/Base.lproj/ShareViewController.xib').output"), formula)
        XCTAssertTrue(formula.contains("product '\(shareResources)/icon.icns' = StaticFile(path: 'input:/nnw/Mac/ShareExtension/icon.icns').output"),
                      formula)
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
        XCTAssertFalse(formula.contains("product '\(macResources)/Sepia.nnwtheme'"), formula)
    }

    /// Every setting the Mac plists name reaches the builder: run over the project's own
    /// plists with what the formula hands it, none is undefined, and the values are the
    /// evaluated ones — the signing team's prefix empty, as no team signs.
    func test_theInfoPlistBuilderIsHandedEverySettingThePlistsName() throws {
        let formula = try netNewsWireFormula()
        let bundles = [("NetNewsWire.app/Contents/Info.plist", "Mac/Resources/Info.plist"),
                       ("NetNewsWire.app/Contents/PlugIns/NetNewsWire Share Extension.appex/Contents/Info.plist", "Mac/ShareExtension/Info.plist"),
                       ("NetNewsWire.app/Contents/PlugIns/Subscribe to Feed.appex/Contents/Info.plist", "Mac/SafariExtension/Info.plist")]
        var plists: [String: [String: Any]] = [:]
        for (product, basePath) in bundles {
            plists[basePath] = try buildInfoPlist(product: product, formula: formula, base: basePath)
        }

        let app = try XCTUnwrap(plists["Mac/Resources/Info.plist"])
        XCTAssertEqual(app["OrganizationIdentifier"] as? String, "com.ranchero")
        XCTAssertEqual(app["AppGroup"] as? String, "group.com.ranchero.NetNewsWire-Evergreen-DEBUG")
        XCTAssertEqual(app["AppIdentifierPrefix"] as? String, "")
        XCTAssertEqual(app["DeveloperEntitlements"] as? String, "")
        XCTAssertNil(app["PRODUCT_NAME"], "a build setting is a variable, not an entry")
        XCTAssertEqual(try XCTUnwrap(plists["Mac/ShareExtension/Info.plist"])["AppGroup"] as? String, "group.com.ranchero.NetNewsWire-Evergreen")
    }

    /// The plist the formula's `InfoPlistBuilder` for `product` builds over the fixture's
    /// copy of the project's plist, failing the test if it reports anything undefined.
    private func buildInfoPlist(product: String, formula: String, base: String) throws -> [String: Any] {
        let pattern = "product '" + NSRegularExpression.escapedPattern(for: product) + "' =\\n    InfoPlistBuilder\\(\\n"
                    + "        keys: '([^']*)',\\n        buildSettings: '([^']*)',"
        let match = try XCTUnwrap(try NSRegularExpression(pattern: pattern).firstMatch(in: formula, range: NSRange(formula.startIndex..., in: formula)),
                                  "no InfoPlistBuilder for \(product)")
        let keys = String(formula[try XCTUnwrap(Range(match.range(at: 1), in: formula))])
        let settings = String(formula[try XCTUnwrap(Range(match.range(at: 2), in: formula))])
        let node = try InfoPlistBuilder(thisNode: NodeRecord(id: 1, kind: InfoPlistBuilder.kind, name: nil,
                                                             properties: [InfoPlistBuilder.keysProperty: keys,
                                                                          InfoPlistBuilder.buildSettingsProperty: settings],
                                                             scheduled: false, identity: nil))
        let baseBytes = try Data(contentsOf: XcodeBuildSettingsTests.netNewsWire.appendingPathComponent(base))
        let output = try node.process(input: ProcessInput(inputValues: [InfoPlistBuilder.base: ["base": .value(try [UInt8](baseBytes).intern())]]))
        let plist = try XCTUnwrap(output.outputValues[InfoPlistBuilder.output])
        guard case .value(let hash) = plist else {
            if case .noValue(.error(let messageHash)) = plist {
                XCTFail("\(base): \(try messageHash.resolveAsString())")
            }
            return [:]
        }
        let bytes = try XCTUnwrap(try DataObjectStore.shared.read(hash: hash))
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any])
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
        XCTAssertTrue(absentFormula.contains("\"CFBundleIdentifier\":\"com.ranchero.NetNewsWire-Evergreen-DEBUG\""), absentFormula)

        let (present, _, _) = try convertNetNewsWire(modules: NetNewsWireModules.products.keys.sorted(), folders: netNewsWireMacFolder,
                                                     xcconfigs: [developerSettings: "ORGANIZATION_IDENTIFIER = org.example"])
        let presentFormula = try XCTUnwrap(present.outputValues[XcodeProjectConverter.formulaOutput]).expectValue().resolveAsString()
        XCTAssertTrue(presentFormula.contains("\"CFBundleIdentifier\":\"org.example.NetNewsWire-Evergreen-DEBUG\""), presentFormula)
    }
}
