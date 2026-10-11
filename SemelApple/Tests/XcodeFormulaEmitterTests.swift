//
//  XcodeFormulaEmitterTests.swift
//  SemelAppleTests
//
//  The formula for the fixture project's application: what a hand-written one for the
//  same app would say, with every path and setting taken from the project.
//

@testable import SemelApple
import XCTest

final class XcodeFormulaEmitterTests: XCTestCase {

    private let build = XcodeFormulaEmitter.Build(root: "input:/repo", projectFolder: "input:/repo",
                                                  configuration: "Debug", sdk: "iphonesimulator")

    private func emitter() throws -> XcodeFormulaEmitter {
        XcodeFormulaEmitter(project: try XcodeProject(pbxproj: Data(XcodeProjectTests.fixture.utf8)), build: build)
    }

    private func formula(listing: XcodeFormulaEmitter.FolderListing = .init(
                            files: ["App.swift", "Views/Home.swift", "Info.plist", "Fonts/Mono.ttf", "Embeds/glass.wav",
                                    "Resources/Localizable.xcstrings", "Assets.xcassets/Contents.json", "README.md"],
                            folders: ["Views", "Fonts", "Embeds", "Resources", "Assets.xcassets"]),
                         xcconfig: String = "") throws -> String {
        let emitter = try emitter()
        return try emitter.formula(
            for: try XCTUnwrap(emitter.project.applications.first),
            settings: { target in
                try XcodeBuildSettings.resolve(project: emitter.project, target: target, configuration: "Debug", sdk: "iphonesimulator",
                                               xcconfig: { _ in Xcconfig.assignments("BUNDLE_ID_PREFIX = com.example\n" + xcconfig) },
                                               extra: ["TARGET_NAME": target.name])
            },
            listing: { $0 == "input:/repo/IceCubesApp" ? listing : nil })
    }

    /// The formula for the grouped fixture (B-77): a target that lists its files.
    private func groupedFormula(pbxproj: String = XcodeProjectTests.groupedFixture) throws -> String {
        let emitter = XcodeFormulaEmitter(project: try XcodeProject(pbxproj: Data(pbxproj.utf8)), build: build)
        return try emitter.formula(
            for: try XCTUnwrap(emitter.project.applications.first),
            settings: { target in
                try XcodeBuildSettings.resolve(project: emitter.project, target: target, configuration: "Debug", sdk: "iphonesimulator",
                                               xcconfig: { _ in nil }, extra: ["TARGET_NAME": target.name])
            },
            listing: { _ in nil })
    }

    // MARK: - A target that lists its files (B-77)

    /// Each listed source goes to the compiler by itself, keyed by its whole path — two
    /// groups may each hold a `View.swift` — and there is no folder to walk.
    func test_compilesListedSourcesOneByOne() throws {
        let formula = try groupedFormula()

        XCTAssertTrue(formula.contains("func compiler_Food_Truck() =\n    SwiftCompiler("), formula)
        XCTAssertFalse(formula.contains("inputFolder:"), formula)
        XCTAssertTrue(formula.contains("extraSourceFiles: [\n"
                                       + "        'App/App.swift': StaticFile(path: 'input:/repo/App/App.swift').output,\n"
                                       + "        'App/Views/Home.swift': StaticFile(path: 'input:/repo/App/Views/Home.swift').output,\n"
                                       + "        'Shared/Sources/Util.swift': StaticFile(path: 'input:/repo/Shared/Sources/Util.swift').output,\n"
                                       + "        'GeneratedAssetSymbols.swift': assets_Food_Truck().swiftAssetSymbols\n"
                                       + "        ]"), formula)
        XCTAssertTrue(formula.contains("'FoodKit': modules_FoodKit().files"), formula)
    }

    /// The resources phase's files: the catalog compiled, a localized file kept under its
    /// `.lproj`, a plain file flat, and the Info.plist read as the plist's base rather
    /// than copied.
    func test_copiesListedResourcesWithLocalizedOnesUnderTheirLanguageFolder() throws {
        let formula = try groupedFormula()

        XCTAssertTrue(formula.contains("'Assets.xcassets': Folder(path: 'input:/repo/App/Assets.xcassets').manifest"), formula)
        XCTAssertTrue(formula.contains("product 'Food Truck.app/en.lproj/Localizable.strings' = StaticFile(path: 'input:/repo/App/en.lproj/Localizable.strings').output"), formula)
        XCTAssertTrue(formula.contains("product 'Food Truck.app/ar.lproj/Localizable.strings' = StaticFile(path: 'input:/repo/App/ar.lproj/Localizable.strings').output"), formula)
        XCTAssertTrue(formula.contains("product 'Food Truck.app/LICENSE.txt' = StaticFile(path: 'input:/repo/LICENSE.txt').output"), formula)
        XCTAssertTrue(formula.contains("base: ['base': StaticFile(path: 'input:/repo/App/Food-Info.plist').output]"), formula)
        XCTAssertFalse(formula.contains("product 'Food Truck.app/Food-Info.plist'"), formula)
    }

    /// A dot-named file the resources phase lists — CodeEdit's `.all-contributorsrc`, which
    /// its About window reads from the bundle — is a resource by its exact path, copied
    /// under its own name: the `StaticFile` that a build follows and a push of its path
    /// sends, though a walk of the folder passes it over (B-77 item 5).
    func test_aListedDotNamedResourceIsCopiedByItsPath() throws {
        let pbxproj = XcodeProjectTests.groupedFixture
            .replacingOccurrences(of: "path = LICENSE.txt;", with: "path = .all-contributorsrc;")
        let formula = try groupedFormula(pbxproj: pbxproj)

        XCTAssertTrue(formula.contains("product 'Food Truck.app/.all-contributorsrc' = StaticFile(path: 'input:/repo/.all-contributorsrc').output"),
                      formula)
    }

    /// A listed source that is neither Swift nor C-family is a build this converter cannot
    /// write yet, and it says which files rather than compiling around them.
    func test_aListedSourceThatIsNotSwiftOrCFamilyIsRefusedByName() throws {
        let pbxproj = XcodeProjectTests.groupedFixture
            .replacingOccurrences(of: "path = Util.swift;", with: "path = Util.metal;")
        XCTAssertThrowsError(try groupedFormula(pbxproj: pbxproj)) { error in
            XCTAssertEqual("\(error)", "Food Truck: sources that are not Swift are not compiled yet: Shared/Sources/Util.metal")
        }
    }

    /// A documentation catalog in the sources phase — CodeEdit lists `Documentation.docc`
    /// — builds nothing a build uses, and is passed over rather than refused (B-77).
    func test_aListedDocumentationCatalogIsPassedOver() throws {
        let pbxproj = XcodeProjectTests.groupedFixture
            .replacingOccurrences(of: "F4 = { isa = PBXFileReference; lastKnownFileType = text; path = LICENSE.txt;",
                                  with: "F4 = { isa = PBXFileReference; lastKnownFileType = folder.documentationcatalog; path = Documentation.docc;")
            .replacingOccurrences(of: "BP1 = { isa = PBXSourcesBuildPhase; files = ( BF1, BF2, BF3 ); };",
                                  with: "BP1 = { isa = PBXSourcesBuildPhase; files = ( BF1, BF2, BF3, BF8 ); };\n"
                                      + "BF8 = { isa = PBXBuildFile; fileRef = F4; };")
            .replacingOccurrences(of: "files = ( BF4, BF5, BF6 )", with: "files = ( BF4, BF5 )")
        let formula = try groupedFormula(pbxproj: pbxproj)

        XCTAssertTrue(formula.contains("'App/App.swift': StaticFile(path: 'input:/repo/App/App.swift').output"), formula)
        XCTAssertFalse(formula.contains("Documentation.docc"), formula)
    }

    /// A listed Objective-C source is compiled through clang and linked beside the Swift.
    /// It finds the project's headers through the header map, laid out — every header
    /// the project references on `-iquote` by its folder, and by name under the product —
    /// and its own folder is no search path (B-77 item 4).
    func test_aListedObjectiveCSourceIsCompiledAndLinked() throws {
        let pbxproj = XcodeProjectTests.groupedFixture
            .replacingOccurrences(of: "path = Util.swift;", with: "path = Util.m;")
            .replacingOccurrences(of: "path = LICENSE.txt;", with: "path = Util.h;")
        let formula = try groupedFormula(pbxproj: pbxproj)

        XCTAssertTrue(formula.contains("func preprocess_Food_Truck(path) =\n    ClangPreprocessor("), formula)
        XCTAssertFalse(formula.contains("headerFolders:"), formula)
        XCTAssertTrue(formula.contains("func headers_Food_Truck() =\n    TreeBuilder(input: [\n"
                                       + "        'Util.h': StaticFile(path: 'input:/repo/Util.h').output\n    ]).files"), formula)
        XCTAssertTrue(formula.contains("SettingsLiteral(headerMapProduct: 'Food Truck', target: 'arm64-apple-ios16.4-simulator')"),
                      "the preprocessor lays the headers under the product too: \(formula)")
        XCTAssertTrue(formula.contains("        quoteHeaderTrees: ['input:/repo': headers_Food_Truck().files],\n"
                                       + "        headerTrees: ['derived-headers': TreeBuilder(input: ['Food_Truck-Swift.h': compiler_Food_Truck().objectiveCHeader, "
                                       + "'Food Truck/Food_Truck-Swift.h': compiler_Food_Truck().objectiveCHeader]).files]"), formula)
        XCTAssertTrue(formula.contains("'input:/repo/Shared/Sources/Util.m.o': ClangCompiler("), formula)
        XCTAssertTrue(formula.contains("input: ['input:/repo/Shared/Sources/Util.m.p': preprocess_Food_Truck(path: 'input:/repo/Shared/Sources/Util.m')], "
                                       + "frameworkTrees: ['FoodKit': frameworks_FoodKit().files], moduleTrees: ['FoodKit': modules_FoodKit().files]).output"),
                      formula)
    }

    // MARK: - A macOS bundle (B-77)

    /// The fixture for `macosx`, with `extra` laid over every target's settings.
    private func macFormula(extra: [String: String] = [:],
                            listing: @escaping (String) -> XcodeFormulaEmitter.FolderListing? = { _ in nil }) throws -> String {
        let macBuild = XcodeFormulaEmitter.Build(root: "input:/repo", projectFolder: "input:/repo", configuration: "Debug", sdk: "macosx")
        let emitter = XcodeFormulaEmitter(project: try XcodeProject(pbxproj: Data(XcodeProjectTests.fixture.utf8)), build: macBuild)
        return try emitter.formula(
            for: try XCTUnwrap(emitter.project.applications.first),
            settings: { target in
                let resolved = try XcodeBuildSettings.resolve(project: emitter.project, target: target, configuration: "Debug", sdk: "macosx",
                                                              xcconfig: { _ in Xcconfig.assignments("BUNDLE_ID_PREFIX = com.example") },
                                                              extra: ["TARGET_NAME": target.name])
                return XcodeBuildSettings(values: resolved.values.merging(extra) { _, new in new })
            },
            listing: listing)
    }

    /// One block of the formula: the func or product that opens with `opening`.
    private func block(_ opening: String, in formula: String) throws -> String {
        try XCTUnwrap(formula.components(separatedBy: "\n\n").first { $0.hasPrefix(opening) }, "no block opening \(opening) in\n\(formula)")
    }

    /// The same fixture for `macosx`: one tree, the bundle, with the executable under
    /// `Contents/MacOS`, the plist directly in `Contents`, every resource under
    /// `Contents/Resources`, the extension under `Contents/PlugIns` with a `Contents` of its
    /// own, and the identity a Mac bundle has — the Mac as the one device, the deployment
    /// target under `LSMinimumSystemVersion`, no `UIDeviceFamily`.
    func test_aMacBundleHasAContentsFolderWithMacOSResourcesAndPlugIns() throws {
        let formula = try macFormula(extra: ["MACOSX_DEPLOYMENT_TARGET": "13.3"],
                                     listing: { $0 == "input:/repo/IceCubesApp" ? .init(files: ["App.swift", "Fonts/Mono.ttf"], folders: ["Fonts"]) : nil })

        let bundle = try block("func bundle_IceCubesApp() = TreeMerger(input: [", in: formula)
        XCTAssertTrue(bundle.contains("    'files': TreeBuilder(input: [\n        'Contents/MacOS/Ice Cubes': SwiftLinker(\n"), bundle)
        XCTAssertTrue(bundle.contains("        'Contents/Info.plist': infoPlist_IceCubesApp().plist"), bundle)
        XCTAssertTrue(bundle.contains("        'Contents/Resources/Mono.ttf': StaticFile(path: 'input:/repo/IceCubesApp/Fonts/Mono.ttf').output"), bundle)
        XCTAssertTrue(bundle.contains("    'Contents/Resources': TreeMerger(under: 'Contents/Resources', input: ['assets': assets_IceCubesApp().files"), bundle)
        XCTAssertTrue(bundle.contains("    'Contents/PlugIns/IceCubesShareExtension.appex': TreeMerger(under: 'Contents/PlugIns/IceCubesShareExtension.appex', "
                                      + "input: ['IceCubesShareExtension.appex': signed_IceCubesShareExtension().files]).files"), bundle)
        let appex = try block("func bundle_IceCubesShareExtension() = TreeMerger(input: [", in: formula)
        XCTAssertTrue(appex.contains("        'Contents/MacOS/IceCubesShareExtension': SwiftLinker(\n"), appex)
        XCTAssertEqual(formula.components(separatedBy: "\nproduct ").count - 1, 1, "the signed bundle is the one product: \(formula)")
        XCTAssertTrue(formula.hasSuffix("\nproduct 'Ice Cubes.app/' = signed_IceCubesApp().files\n"), formula)
        XCTAssertTrue(formula.contains("target: 'arm64-apple-macosx13.3'"), formula)
        XCTAssertTrue(formula.contains("platform: 'macosx'"), formula)
        XCTAssertTrue(formula.contains("targetDevices: 'mac'"), formula)
        XCTAssertTrue(formula.contains("\"LSMinimumSystemVersion\":\"13.3\""), formula)
        XCTAssertFalse(formula.contains("MinimumOSVersion\""), formula)
        XCTAssertFalse(formula.contains("UIDeviceFamily"), formula)
        XCTAssertFalse(formula.contains("LSRequiresIPhoneOS"), formula)
    }

    /// Every package product's binary frameworks (B-77): compiled and linked against, found
    /// at run time under `Contents/Frameworks`, and the dynamic ones embedded there —
    /// `embedded_P()`, so a static framework is linked and neither embedded nor signed
    /// (B-77 item 12) — named for every product, since both are empty for one that reaches
    /// none.
    func test_aMacBundleEmbedsThePackagesFrameworksUnderContentsFrameworks() throws {
        let formula = try macFormula()

        let trees = "frameworkTrees: [\n        'KeychainSwift': frameworks_KeychainSwift().files,\n        'Timeline': frameworks_Timeline().files\n        ]"
        let compiler = try block("func compiler_IceCubesApp()", in: formula)
        XCTAssertTrue(compiler.contains(trees), compiler)
        let bundle = try block("func bundle_IceCubesApp()", in: formula)
        let linkerTrees = "frameworkTrees: [\n            'KeychainSwift': frameworks_KeychainSwift().files,\n"
                        + "            'Timeline': frameworks_Timeline().files\n            ]"
        XCTAssertTrue(bundle.contains(linkerTrees), bundle)
        XCTAssertTrue(bundle.contains("frameworksRunpath: '@executable_path/../Frameworks'"), bundle)
        XCTAssertTrue(bundle.contains("    'Contents/Frameworks': TreeMerger(under: 'Contents/Frameworks', input: [\n"
                                      + "        'KeychainSwift': embedded_KeychainSwift().files,\n"
                                      + "        'Timeline': embedded_Timeline().files\n    ]).files"), bundle)
        XCTAssertFalse(bundle.contains("'Contents/Frameworks': TreeMerger(under: 'Contents/Frameworks', input: [\n        'KeychainSwift': frameworks_"),
                       "what is linked against is not what is embedded: \(bundle)")
    }

    // MARK: - Signing a Mac bundle (B-77)

    /// The bundle is signed once it is whole, ad-hoc, by the signer the machine's
    /// settings name; the extension is signed by its own signer before the app embeds it,
    /// and the app's signer signs it again with the rest.
    func test_aMacBundleIsSignedAdHocOnceItIsWhole() throws {
        let formula = try macFormula()

        let signer = try block("func signed_IceCubesApp() =\n    CodeSigner(", in: formula)
        XCTAssertTrue(signer.contains("ConfigFilter(prefix: 'apple.codeSigner'"), signer)
        XCTAssertTrue(signer.contains("SettingsLiteral(identity: '-')"), signer)
        XCTAssertTrue(signer.contains("bundle: ['Ice Cubes.app': bundle_IceCubesApp().files]"), signer)
        XCTAssertFalse(signer.contains("entitlements:"), "the fixture names none: \(signer)")
        let appexSigner = try block("func signed_IceCubesShareExtension() =\n    CodeSigner(", in: formula)
        XCTAssertTrue(appexSigner.contains("bundle: ['IceCubesShareExtension.appex': bundle_IceCubesShareExtension().files]"), appexSigner)
        XCTAssertLessThan(try XCTUnwrap(formula.range(of: "func signed_IceCubesShareExtension()")).lowerBound,
                          try XCTUnwrap(formula.range(of: "func bundle_IceCubesApp()")).lowerBound,
                          "the extension is signed before the app's bundle embeds it")
    }

    /// `CODE_SIGN_ENTITLEMENTS` is signed with, its `$(VAR)`s resolved over the target's
    /// settings as the Info.plist's are.
    func test_theEntitlementsAreTheFileTheSettingsName() throws {
        let formula = try macFormula(extra: ["CODE_SIGN_ENTITLEMENTS": "$(SRCROOT)/App/App.entitlements"])

        let signer = try block("func signed_IceCubesApp() =\n    CodeSigner(", in: formula)
        XCTAssertTrue(signer.contains("        entitlements: ['entitlements': InfoPlistBuilder(\n            buildSettings: '{"), signer)
        XCTAssertTrue(signer.contains("\"PRODUCT_BUNDLE_IDENTIFIER\":\"com.example.IceCubesApp\""), signer)
        XCTAssertTrue(signer.contains("            base: ['base': StaticFile(path: 'input:/repo/App/App.entitlements').output]\n        ).plist]"), signer)
    }

    /// The sandbox and hardened-runtime settings are entitlements Xcode signs with, laid
    /// over the file's: CodeEdit's app sets `RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION`,
    /// without which its hardened app cannot load Sparkle (B-77). A setting alone, with no
    /// file, is entitlements too; `NO` and an empty access level are none.
    func test_theSandboxAndRuntimeSettingsAreEntitlements() throws {
        let settings: [String: String] = [
            "CODE_SIGN_ENTITLEMENTS": "App/App.entitlements",
            "ENABLE_APP_SANDBOX": "YES",
            "RUNTIME_EXCEPTION_ALLOW_JIT": "YES",
            "RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION": "YES",
            "ENABLE_INCOMING_NETWORK_CONNECTIONS": "NO",
            "ENABLE_USER_SELECTED_FILES": "readwrite",
            "ENABLE_FILE_ACCESS_DOWNLOADS_FOLDER": "readonly",
            "ENABLE_FILE_ACCESS_MUSIC_FOLDER": "",
        ]
        let signer = try block("func signed_IceCubesApp() =\n    CodeSigner(", in: try macFormula(extra: settings))
        XCTAssertTrue(signer.contains("        entitlements: ['entitlements': InfoPlistBuilder(\n"
                                      + "            keys: '{\"com.apple.security.app-sandbox\":true,"
                                      + "\"com.apple.security.cs.allow-jit\":true,"
                                      + "\"com.apple.security.cs.disable-library-validation\":true,"
                                      + "\"com.apple.security.files.downloads.read-only\":true,"
                                      + "\"com.apple.security.files.user-selected.read-write\":true}',\n"), signer)
        XCTAssertTrue(signer.contains("            base: ['base': StaticFile(path: 'input:/repo/App/App.entitlements').output]\n        ).plist]"), signer)

        let settingsAlone = try block("func signed_IceCubesApp() =\n    CodeSigner(",
                                      in: try macFormula(extra: ["RUNTIME_EXCEPTION_DISABLE_LIBRARY_VALIDATION": "YES"]))
        XCTAssertTrue(settingsAlone.contains("keys: '{\"com.apple.security.cs.disable-library-validation\":true}'"), settingsAlone)
        XCTAssertFalse(settingsAlone.contains("base: ['base': StaticFile"), settingsAlone)
    }

    /// A named identity is read and said: Semel signs ad-hoc, whatever certificate the
    /// project names.
    func test_aNamedIdentityIsSaidAndSignedAdHoc() throws {
        let formula = try macFormula(extra: ["CODE_SIGN_IDENTITY": "Apple Development"])

        XCTAssertTrue(formula.contains("// CODE_SIGN_IDENTITY is 'Apple Development': signed ad-hoc, as Semel signs with no certificate (B-77).\n"
                                       + "func signed_IceCubesApp() =\n    CodeSigner("), formula)
        XCTAssertFalse(try macFormula(extra: ["CODE_SIGN_IDENTITY": "-"]).contains("// CODE_SIGN_IDENTITY"))
    }

    /// `CODE_SIGNING_ALLOWED = NO` is an unsigned bundle, as in Xcode.
    func test_aTargetThatAllowsNoSigningIsNotSigned() throws {
        let formula = try macFormula(extra: ["CODE_SIGNING_ALLOWED": "NO"])

        XCTAssertFalse(formula.contains("CodeSigner("), formula)
        XCTAssertTrue(formula.hasSuffix("\nproduct 'Ice Cubes.app/' = bundle_IceCubesApp().files\n"), formula)
        XCTAssertTrue(formula.contains("input: ['IceCubesShareExtension.appex': bundle_IceCubesShareExtension().files]"), formula)
    }

    /// The simulator runs an unsigned bundle, and one is what it gets: no signer, and each
    /// part the product it was.
    func test_anIOSBundleIsNotSigned() throws {
        let formula = try formula()

        XCTAssertFalse(formula.contains("CodeSigner("), formula)
        XCTAssertFalse(formula.contains("func bundle_"), formula)
        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/Ice Cubes' =\n    SwiftLinker("), formula)
    }

    /// An iOS bundle is flat: the frameworks under `Frameworks/`, found beside the executable.
    func test_anIOSBundleEmbedsThePackagesFrameworksUnderFrameworks() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/Frameworks/' = TreeMerger(input: [\n"
                                       + "        'KeychainSwift': embedded_KeychainSwift().files,"), formula)
        XCTAssertTrue(formula.contains("frameworksRunpath: '@executable_path/Frameworks'"), formula)
    }

    /// The resource bundles of every package the target links travel into the bundle's
    /// tree, named per product so the app needs no knowledge of which targets carry any.
    func test_mergesThePackagesResourceBundlesIntoTheBundle() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("'bundles_KeychainSwift': bundles_KeychainSwift().files"), formula)
        XCTAssertTrue(formula.contains("'bundles_Timeline': bundles_Timeline().files"), formula)
        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/' = TreeMerger(input: ["), formula)
    }

    /// A Mac bundle takes them laid out as Mac bundles, `Contents/Resources/` with an
    /// Info.plist beside it, under its own `Contents/Resources` (B-77).
    func test_aMacBundleMergesThePackagesResourceBundlesLaidOutForTheMac() throws {
        let formula = try macFormula()

        let bundle = try block("func bundle_IceCubesApp()", in: formula)
        XCTAssertTrue(bundle.contains("'macBundles_KeychainSwift': macBundles_KeychainSwift().files"), bundle)
        XCTAssertTrue(bundle.contains("'macBundles_Timeline': macBundles_Timeline().files"), bundle)
        XCTAssertFalse(formula.contains("bundles_KeychainSwift()") && formula.contains("'bundles_KeychainSwift'"), formula)
    }

    func test_aLocalizedFileKeepsItsLanguageFolderAndNothingAbove() {
        XCTAssertEqual(XcodeFormulaEmitter.localizedBundlePath("App/ar.lproj/Localizable.strings"), "ar.lproj/Localizable.strings")
        XCTAssertEqual(XcodeFormulaEmitter.localizedBundlePath("Base.lproj/Main.storyboard"), "Base.lproj/Main.storyboard")
        XCTAssertNil(XcodeFormulaEmitter.localizedBundlePath("App/Fonts/Mono.ttf"))
        XCTAssertNil(XcodeFormulaEmitter.localizedBundlePath("en.lproj"), "a folder, not a file in one")
    }

    // MARK: - Packages

    /// Every local package the project references, and each remote one where the
    /// vendoring rule puts it, under the one build root.
    func test_includesEveryPackageTheProjectReferences() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("include funcs SwiftFormulaConverter(path: 'input:/repo/Packages/Timeline', root: 'input:/repo').formula"), formula)
        XCTAssertTrue(formula.contains("include funcs SwiftFormulaConverter(path: 'input:/repo/Packages/Models', root: 'input:/repo').formula"), formula)
        XCTAssertTrue(formula.contains("include funcs SwiftFormulaConverter(path: 'input:/repo/Dependencies/keychain-swift', root: 'input:/repo').formula"), formula)
    }

    /// The local packages are the ones the converter hands over — found in a synchronized
    /// folder as well as declared — each included once, at its path with any `..` resolved,
    /// so a package another one reaches by path is the same node either way.
    func test_includesEveryLocalPackageItIsGivenAtItsResolvedPath() throws {
        let project = try XcodeProject(pbxproj: Data(XcodeProjectTests.fixture.utf8))
        let emitter = XcodeFormulaEmitter(project: project, build: build,
                                          localPackagePaths: ["../Shared/Kit", "Modules/Networking", "Packages/Timeline"])

        let includes = emitter.includes(for: project.targets)

        XCTAssertEqual(includes, [
            "include funcs SwiftFormulaConverter(path: 'input:/Shared/Kit', root: 'input:/repo').formula",
            "include funcs SwiftFormulaConverter(path: 'input:/repo/Dependencies/keychain-swift', root: 'input:/repo').formula",
            "include funcs SwiftFormulaConverter(path: 'input:/repo/Modules/Networking', root: 'input:/repo').formula",
            "include funcs SwiftFormulaConverter(path: 'input:/repo/Packages/Timeline', root: 'input:/repo').formula",
        ])
    }

    // MARK: - Sources and the executable

    func test_compilesTheSynchronizedFolderAgainstTheLinkedProductsModules() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("func compiler_IceCubesApp() =\n    SwiftCompiler("), formula)
        XCTAssertTrue(formula.contains("moduleName: 'Ice_Cubes'"), formula)
        XCTAssertTrue(formula.contains("excludedPaths: 'Embeds/glass.wav,Info.plist'"), formula)
        XCTAssertTrue(formula.contains("languageMode: '6'"), formula)
        XCTAssertTrue(formula.contains("target: 'arm64-apple-ios18.5-simulator'"), formula)
        XCTAssertTrue(formula.contains("defines: 'DEBUG,EXTRA'"), formula)
        XCTAssertTrue(formula.contains("inputFolder: [\n        'folder0': Folder(path: 'input:/repo/IceCubesApp').manifest\n        ]"), formula)
        XCTAssertTrue(formula.contains("'KeychainSwift': modules_KeychainSwift().files"), formula)
        XCTAssertTrue(formula.contains("'Timeline': modules_Timeline().files"), formula)
        XCTAssertTrue(formula.contains("ConfigFilter(prefix: 'swift.compiler', input: ['config': ConfigMerger(base: ['machine': StaticFile(path: 'input:/repo/semel.machine.config').output], override: ['project': StaticFile(path: 'input:/repo/semel.config').output]).output])"), formula)
    }

    /// The target's own values are a `SettingsLiteral` a `ConfigMerger` lays over the
    /// selected settings (B-120): the merger's base is the selector, its override the
    /// literal, so a value the target states wins over the config file.
    func test_theTargetsValuesAreALiteralLaidOverTheSelectedSettings() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("configuration: ['config': ConfigMerger(base: ['settings': ConfigFilter(prefix: 'swift.compiler', "), formula)
        XCTAssertTrue(formula.contains("override: ['literals': SettingsLiteral(defines: 'DEBUG,EXTRA', "), formula)
        XCTAssertFalse(formula.contains("Configuration("), formula)
    }

    func test_linksTheExecutableIntoTheBundleWithTheProductsObjectsAndFrameworks() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/Ice Cubes' =\n    SwiftLinker("), formula)
        XCTAssertTrue(formula.contains("linkage: 'executable'"), formula)
        XCTAssertTrue(formula.contains("outputName: 'Ice Cubes'"), formula)
        XCTAssertTrue(formula.contains("arguments: '-framework,QuickLook'"), formula)
        XCTAssertTrue(formula.contains("input: ['Ice_Cubes.o': compiler_IceCubesApp().object]"), formula)
        XCTAssertTrue(formula.contains("'Timeline': objects_Timeline().files"), formula)
    }

    /// The linker takes what each package product's objects need beyond themselves — its
    /// targets' frameworks and libraries, the C++ runtime — as the package's formula states
    /// it, and links their union (B-55).
    func test_linksWhatEachPackageProductsObjectsNeed() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("linkRequirements: [\n        'KeychainSwift': linking_KeychainSwift().output,\n"
                                     + "        'Timeline': linking_Timeline().output\n        ]"), formula)
    }

    // MARK: - Objective-C in the application (B-77)

    /// The app's folder with Objective-C in it, a bridging header, and a header an
    /// exception leaves out, as NetNewsWire's `Mac` folder has.
    private let objectiveCListing = XcodeFormulaEmitter.FolderListing(
        files: ["App.swift", "Info.plist", "Embeds/glass.wav", "App-Bridging-Header.h",
                "Legacy/Greeter.h", "Legacy/Greeter.m", "Legacy/Cruncher.mm", "Legacy/Private/Secret.h"],
        folders: ["Embeds", "Legacy", "Legacy/Private"])

    private let objectiveCSettings = """
        SWIFT_OBJC_BRIDGING_HEADER = $(SRCROOT)/IceCubesApp/App-Bridging-Header.h
        CLANG_ENABLE_OBJC_ARC = YES
        CLANG_ENABLE_MODULES = YES
        GCC_C_LANGUAGE_STANDARD = gnu11
        GCC_PREPROCESSOR_DEFINITIONS = DEBUG=1 FEATURE
        """

    /// Every C-family source of the folder is preprocessed over the folder as its header
    /// folder and compiled with ARC, modules and the project's standard, as the package
    /// converter compiles a C target's, and linked with the Swift; Objective-C++ brings the
    /// C++ runtime.
    func test_compilesTheFoldersObjectiveCAndLinksItBesideTheSwift() throws {
        let formula = try formula(listing: objectiveCListing, xcconfig: objectiveCSettings)

        XCTAssertTrue(formula.contains("func preprocess_IceCubesApp(path) =\n    ClangPreprocessor(\n"
                                       + "        configuration: ['config': ConfigMerger(base: ['settings': ConfigFilter(prefix: 'clang.preprocessor', "),
                      formula)
        XCTAssertTrue(formula.contains("SettingsLiteral(cStandard: 'gnu11', defines: 'DEBUG=1,FEATURE', headerMapProduct: 'Ice Cubes', modules: 'true', objectiveCARC: 'true', "
                                       + "target: 'arm64-apple-ios18.5-simulator')"), formula)
        XCTAssertTrue(formula.contains("        input: [path: StaticFile(path: path)],\n        headerFolders: [\n"
                                       + "            'input:/repo/IceCubesApp': Folder(path: 'input:/repo/IceCubesApp').manifest\n        ]"),
                      formula)
        XCTAssertTrue(formula.contains("input: [\n            'Ice_Cubes.o': compiler_IceCubesApp().object,\n"
                                       + "            'input:/repo/IceCubesApp/Legacy/Cruncher.mm.o': ClangCompiler("), formula)
        XCTAssertTrue(formula.contains("'input:/repo/IceCubesApp/Legacy/Greeter.m.o': ClangCompiler(configuration: ['config': "
                                       + "ConfigMerger(base: ['settings': ConfigFilter(prefix: 'clang.compiler', "), formula)
        XCTAssertTrue(formula.contains("SettingsLiteral(cStandard: 'gnu11', modules: 'true', objectiveCARC: 'true', "
                                       + "target: 'arm64-apple-ios18.5-simulator')"), "the compiler takes no defines: \(formula)")
        XCTAssertTrue(formula.contains("input: ['input:/repo/IceCubesApp/Legacy/Greeter.m.p': "
                                       + "preprocess_IceCubesApp(path: 'input:/repo/IceCubesApp/Legacy/Greeter.m')], frameworkTrees: "), formula)
        XCTAssertTrue(formula.contains("'IceCubesApp C++': SettingsLiteral(cxxRuntime: 'true').output"), formula)
        XCTAssertFalse(formula.contains("product 'Ice Cubes.app/Greeter.h'"), "a header is no resource: \(formula)")
    }

    /// The bridging header reaches the Swift compiler by itself, with the folder's other
    /// headers as the tree it imports from — `headers_<Target>()`, the shape a package's C
    /// target hands a Swift importer — and the macros its C-family sources are
    /// preprocessed with, as Xcode tells the importer.
    /// A search-path setting's words as folders of the project: `$(SRCROOT)/…` and a
    /// relative path alike, `/**` recursive, a quoted path with spaces one word, and what
    /// names no folder of the project — the inherited marker passed over, an absolute
    /// path, a setting nothing defines, one climbing out — kept aside to be said (B-77 item 4).
    func test_searchPathSettingsAreFoldersOfTheProject() {
        let settings = XcodeBuildSettings(values: [
            "HEADER_SEARCH_PATHS": "$(inherited) $(SRCROOT)/include \"$(PROJECT_DIR)/MySQL Client Libraries/include\" vendor/**",
            "USER_HEADER_SEARCH_PATHS": "$(SRCROOT)/** ../Outside /usr/local/include",
            "FRAMEWORK_SEARCH_PATHS": "$(SRCROOT)/Frameworks $(PLATFORM_DIR)/Developer/Library/Frameworks",
        ])
        let paths = XcodeSearchPaths(settings: settings)

        XCTAssertEqual(paths.headerSearchPaths, [.init(path: "include", isRecursive: false),
                                                 .init(path: "MySQL Client Libraries/include", isRecursive: false),
                                                 .init(path: "vendor", isRecursive: true)])
        XCTAssertEqual(paths.userHeaderSearchPaths, [.init(path: "", isRecursive: true)])
        XCTAssertEqual(paths.frameworkSearchPaths, [.init(path: "Frameworks", isRecursive: false)])
        XCTAssertEqual(paths.outside, ["../Outside", "/usr/local/include", "$(PLATFORM_DIR)/Developer/Library/Frameworks"])
        XCTAssertEqual(XcodeSearchPaths.expanded(.init(path: "vendor", isRecursive: true),
                                                 listing: .init(files: [], folders: ["b", "a", "a/deep"])),
                       ["vendor", "vendor/a", "vendor/a/deep", "vendor/b"])
    }

    /// A recursive header search path is its folder and every folder the converter found
    /// below it, each a header folder of the target's preprocessor.
    func test_aRecursiveHeaderSearchPathIsEveryFolderBelowIt() throws {
        let formula = try formula(listing: objectiveCListing,
                                  xcconfig: objectiveCSettings + "\nHEADER_SEARCH_PATHS = $(SRCROOT)/IceCubesApp/**")

        XCTAssertTrue(formula.contains("        headerFolders: [\n"
                                       + "            'input:/repo/IceCubesApp': Folder(path: 'input:/repo/IceCubesApp').manifest,\n"
                                       + "            'input:/repo/IceCubesApp/Embeds': Folder(path: 'input:/repo/IceCubesApp/Embeds').manifest,\n"
                                       + "            'input:/repo/IceCubesApp/Legacy': Folder(path: 'input:/repo/IceCubesApp/Legacy').manifest,\n"
                                       + "            'input:/repo/IceCubesApp/Legacy/Private': Folder(path: 'input:/repo/IceCubesApp/Legacy/Private').manifest\n"
                                       + "        ]"), formula)
    }

    func test_theBridgingHeaderReachesTheSwiftCompilerWithTheTargetsHeaders() throws {
        let formula = try formula(listing: objectiveCListing, xcconfig: objectiveCSettings)

        XCTAssertTrue(formula.contains("func headers_IceCubesApp() =\n    TreeBuilder(input: [\n"
                                       + "        'IceCubesApp/App-Bridging-Header.h': StaticFile(path: 'input:/repo/IceCubesApp/App-Bridging-Header.h').output,\n"
                                       + "        'IceCubesApp/Legacy/Greeter.h': StaticFile(path: 'input:/repo/IceCubesApp/Legacy/Greeter.h').output,\n"
                                       + "        'IceCubesApp/Legacy/Private/Secret.h': StaticFile(path: 'input:/repo/IceCubesApp/Legacy/Private/Secret.h').output\n"
                                       + "    ]).files"), formula)
        XCTAssertTrue(formula.contains(",\n        bridgingHeader: ['IceCubesApp/App-Bridging-Header.h': "
                                       + "StaticFile(path: 'input:/repo/IceCubesApp/App-Bridging-Header.h').output],\n"
                                       + "        headerTrees: ['IceCubesApp': headers_IceCubesApp().files]\n    )"), formula)
        XCTAssertTrue(formula.contains("arguments: '-Xcc,-DDEBUG=1,-Xcc,-DFEATURE', defines: 'DEBUG,EXTRA'"), formula)
    }

    /// A target with neither a C-family source nor a bridging header is compiled and
    /// linked as before: one object, no clang, nothing for the importer.
    func test_aSwiftOnlyTargetNamesNoClangAndNoBridgingHeader() throws {
        let formula = try formula()

        XCTAssertFalse(formula.contains("ClangPreprocessor"), formula)
        XCTAssertFalse(formula.contains("bridgingHeader"), formula)
        XCTAssertFalse(formula.contains("-Xcc"), formula)
    }

    // MARK: - Interface Builder documents (B-77)

    /// A xib is compiled to a nib at its place in the bundle — under its language folder
    /// when it has one — and a storyboard to a `.storyboardc`, each through ibtool for the
    /// target's deployment target and devices, in the target's module, and merged into the
    /// bundle's resources rather than copied.
    func test_compilesInterfaceBuilderDocumentsWhereTheyGoInTheBundle() throws {
        let formula = try formula(listing: .init(files: ["App.swift", "Base.lproj/Card.xib", "Views/Main.storyboard"],
                                                 folders: ["Base.lproj", "Views"]))

        XCTAssertTrue(formula.contains("func interface_IceCubesApp_0() =\n    IBToolCompiler(\n"
                                       + "        configuration: ['config': ConfigMerger(base: ['settings': ConfigFilter(prefix: 'apple.ibToolCompiler', "),
                      formula)
        XCTAssertTrue(formula.contains("SettingsLiteral(minimumDeploymentTarget: '18.5', module: 'Ice_Cubes', targetDevices: 'iphone,ipad')"), formula)
        XCTAssertTrue(formula.contains("document: ['Base.lproj/Card.xib': StaticFile(path: 'input:/repo/IceCubesApp/Base.lproj/Card.xib').output]"),
                      formula)
        XCTAssertTrue(formula.contains("document: ['Main.storyboard': StaticFile(path: 'input:/repo/IceCubesApp/Views/Main.storyboard').output]"),
                      formula)
        XCTAssertTrue(formula.contains("'interface0': interface_IceCubesApp_0().files, 'interface1': interface_IceCubesApp_1().files"), formula)
        XCTAssertFalse(formula.contains("product 'Ice Cubes.app/Base.lproj/Card.xib'"), "compiled, not copied: \(formula)")
    }

    func test_anInterfaceBuilderDocumentIsCompiledAtItsPlaceInTheBundle() {
        XCTAssertEqual(XcodeFormulaEmitter.resource(at: "MainMenu/Base.lproj/MainMenu.xib"), .interfaceBuilder(bundlePath: "Base.lproj/MainMenu.xib"))
        XCTAssertEqual(XcodeFormulaEmitter.resource(at: "About/AboutWindowController.xib"), .interfaceBuilder(bundlePath: "AboutWindowController.xib"))
        XCTAssertEqual(XcodeFormulaEmitter.resource(at: "Base.lproj/Main.storyboard"), .interfaceBuilder(bundlePath: "Base.lproj/Main.storyboard"))
        XCTAssertEqual(XcodeFormulaEmitter.resource(at: "Legacy/Greeter.m"), .ignored)
        XCTAssertEqual(XcodeFormulaEmitter.resource(at: "Legacy/Greeter.h"), .ignored)
    }

    // MARK: - Resources

    func test_compilesTheCatalogsForThePlatformAndMergesThemIntoTheBundle() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("func assets_IceCubesApp() =\n    AssetCatalogCompiler("), formula)
        XCTAssertTrue(formula.contains("appIcon: 'AppIcon'"), formula)
        XCTAssertTrue(formula.contains("minimumDeploymentTarget: '18.5'"), formula)
        XCTAssertTrue(formula.contains("platform: 'iphonesimulator'"), formula)
        XCTAssertTrue(formula.contains("targetDevices: 'iphone,ipad'"), formula)
        XCTAssertTrue(formula.contains("'Assets.xcassets': Folder(path: 'input:/repo/IceCubesApp/Assets.xcassets').manifest"), formula)
        XCTAssertTrue(formula.contains("'AppIcon.icon': Folder(path: 'input:/repo/AppIcon.icon').manifest"), formula)
        XCTAssertTrue(formula.contains("catalog: ['Localizable.xcstrings': StaticFile(path: 'input:/repo/IceCubesApp/Resources/Localizable.xcstrings').output]"), formula)
        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/' = TreeMerger(input: ['assets': assets_IceCubesApp().files, 'strings0': strings_IceCubesApp_0().files, "
                                       + "'bundles_KeychainSwift': bundles_KeychainSwift().files, 'bundles_Timeline': bundles_Timeline().files]).files"), formula)
    }

    // MARK: - Generated asset symbols (B-77 item 10)

    /// By Xcode's default a target's catalogs write their Swift symbols, which the target
    /// compiles as `GeneratedAssetSymbols.swift`: the same actool run, told the target's
    /// bundle identifier, with the extensions off and every framework, unless the settings
    /// say otherwise.
    func test_theCatalogsSymbolsAreCompiledWithTheTargetsSources() throws {
        let formula = try formula()

        let assets = try block("func assets_IceCubesApp() =", in: formula)
        XCTAssertTrue(assets.contains("swiftAssetSymbols: 'YES'"), assets)
        XCTAssertTrue(assets.contains("swiftAssetSymbolExtensions: 'NO'"), assets)
        XCTAssertTrue(assets.contains("assetSymbolFrameworks: 'SwiftUI UIKit AppKit'"), assets)
        XCTAssertTrue(assets.contains("assetSymbolBundleIdentifier: 'com.example.IceCubesApp'"), assets)
        let compiler = try block("func compiler_IceCubesApp() =", in: formula)
        XCTAssertTrue(compiler.contains("extraSourceFiles: [\n        'GeneratedAssetSymbols.swift': assets_IceCubesApp().swiftAssetSymbols\n        ]"),
                      compiler)
        XCTAssertLessThan(try XCTUnwrap(formula.range(of: "func assets_IceCubesApp()")).lowerBound,
                          try XCTUnwrap(formula.range(of: "func compiler_IceCubesApp()")).lowerBound,
                          "a func is defined before the funcs that name it")
    }

    /// CodeEdit's settings: the extensions on, one framework, its own identifier for the
    /// catalog; and a target that turns symbols off compiles none.
    func test_theSymbolSettingsReachActoolAndOffMeansNone() throws {
        let symbols = try formula(xcconfig: "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES\n"
                                          + "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOL_FRAMEWORKS = SwiftUI\n"
                                          + "ASSETCATALOG_COMPILER_BUNDLE_IDENTIFIER = app.codeedit.CodeEdit\n")
        let assets = try block("func assets_IceCubesApp() =", in: symbols)
        XCTAssertTrue(assets.contains("swiftAssetSymbolExtensions: 'YES'"), assets)
        XCTAssertTrue(assets.contains("assetSymbolFrameworks: 'SwiftUI'"), assets)
        XCTAssertTrue(assets.contains("assetSymbolBundleIdentifier: 'app.codeedit.CodeEdit'"), assets)

        let none = try formula(xcconfig: "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS = NO\n")
        XCTAssertFalse(none.contains("swiftAssetSymbols"), none)
        XCTAssertFalse(none.contains("GeneratedAssetSymbols.swift"), none)
    }

    func test_theSymbolSettingsReadBackFromTheLiteralsTheyWrite() {
        let symbols = AssetSymbolSettings(bundleIdentifier: "app.codeedit.CodeEdit", generatesExtensions: true, frameworks: "SwiftUI AppKit")

        XCTAssertEqual(AssetSymbolSettings(literals: symbols.literals), symbols)
        XCTAssertNil(AssetSymbolSettings(literals: ["appIcon": "AppIcon"]))
        XCTAssertEqual(symbols.arguments(writingTo: "GeneratedAssetSymbols.swift"),
                       ["--bundle-identifier", "app.codeedit.CodeEdit", "--generate-swift-asset-symbol-extensions", "YES",
                        "--generate-asset-symbol-framework-support", "SwiftUI AppKit",
                        "--generate-swift-asset-symbols", "GeneratedAssetSymbols.swift"])
    }

    /// A file that is neither source nor compiled is copied into the bundle root, as
    /// Xcode flattens a synchronized folder — a Markdown file too; an exception is not; a
    /// source is not.
    func test_copiesPlainResourcesFlatAndLeavesOutExceptionsAndSources() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/Mono.ttf' = StaticFile(path: 'input:/repo/IceCubesApp/Fonts/Mono.ttf').output"), formula)
        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/README.md' = StaticFile(path: 'input:/repo/IceCubesApp/README.md').output"), formula)
        XCTAssertFalse(formula.contains("product 'Ice Cubes.app/glass.wav'"), "an exception is another target's: \(formula)")
        XCTAssertFalse(formula.contains("product 'Ice Cubes.app/App.swift'"), formula)
        XCTAssertFalse(formula.contains("product 'Ice Cubes.app/Contents.json'"), "inside a catalog: \(formula)")
    }

    // MARK: - Info.plist

    func test_buildsTheInfoPlistFromTheFileTheGeneratedKeysAndActoolsPartial() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("func infoPlist_IceCubesApp() =\n    InfoPlistBuilder("), formula)
        XCTAssertTrue(formula.contains("\"CFBundleIdentifier\":\"com.example.IceCubesApp\""), formula)
        XCTAssertTrue(formula.contains("\"CFBundleExecutable\":\"Ice Cubes\""), formula)
        XCTAssertTrue(formula.contains("\"CFBundlePackageType\":\"APPL\""), formula)
        XCTAssertTrue(formula.contains("\"MinimumOSVersion\":\"18.5\""), formula)
        XCTAssertTrue(formula.contains("\"CFBundleSupportedPlatforms\":[\"iPhoneSimulator\"]"), formula)
        XCTAssertTrue(formula.contains("\"UIDeviceFamily\":[1,2]"), formula)
        XCTAssertTrue(formula.contains("\"UILaunchScreen\":{}"), formula)
        XCTAssertTrue(formula.contains("buildSettings: '{") && formula.contains("\"PRODUCT_NAME\":\"Ice Cubes\""), formula)
        XCTAssertFalse(formula.contains("PRODUCT_NAME: 'Ice Cubes'"), "a build setting is no entry of the plist: \(formula)")
        XCTAssertTrue(formula.contains("base: ['base': StaticFile(path: 'input:/repo/IceCubesApp/Info.plist').output]"), formula)
        XCTAssertTrue(formula.contains("partials: ['assets': assets_IceCubesApp().partialInfoPlist]"), formula)
    }

    /// A value with an apostrophe cannot sit in a single-quoted literal and one with both
    /// quotes in neither; the JSON keys write an apostrophe as `\\u0027`.
    func test_quotesLiteralsWithWhicheverQuoteTheyDoNotContain() throws {
        XCTAssertEqual(XcodeFormulaEmitter.quoted("plain"), "'plain'")
        XCTAssertEqual(XcodeFormulaEmitter.quoted("it's"), "\"it's\"")
        XCTAssertEqual(try XcodeFormulaEmitter.json(["k": "it's"]), "{\"k\":\"it\\u0027s\"}")
    }

    func test_theGeneratedKeysTypeListsAndBooleans() throws {
        let emitter = try emitter()
        let app = try XCTUnwrap(emitter.project.targets.first(where: \.isApplication))
        let settings = XcodeBuildSettings(values: [
            "PRODUCT_NAME": "Ice Cubes", "PRODUCT_MODULE_NAME": "Ice_Cubes", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app",
            "IPHONEOS_DEPLOYMENT_TARGET": "18.0", "TARGETED_DEVICE_FAMILY": "1,2,7", "GENERATE_INFOPLIST_FILE": "YES",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait",
            "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
            "INFOPLIST_KEY_CFBundleDisplayName": "Ice Cubes",
            "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        ])

        let keys = try TargetIdentity(target: app, settings: settings, sdk: "iphonesimulator").generatedInfoPlistKeys(settings: settings)

        XCTAssertEqual(keys["UISupportedInterfaceOrientations"] as? [String],
                       ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft"])
        XCTAssertEqual(keys["UISupportedInterfaceOrientations~ipad"] as? [String], ["UIInterfaceOrientationPortrait"])
        XCTAssertEqual(keys["UIApplicationSceneManifest"] as? [String: Bool], ["UIApplicationSupportsMultipleScenes": true])
        XCTAssertEqual(keys["CFBundleDisplayName"] as? String, "Ice Cubes", "a display name with two words is not a list")
        XCTAssertEqual(keys["UIApplicationSupportsIndirectInputEvents"] as? Bool, true)
        XCTAssertEqual(keys["UIDeviceFamily"] as? [Int], [1, 2], "family 7 is visionOS, not built here")
    }

    /// With `GENERATE_INFOPLIST_FILE = NO` the project's file is the plist and Xcode passes
    /// the `INFOPLIST_KEY_*` settings over: CodeEdit's `INFOPLIST_KEY_NSPrincipalClass`
    /// names `CodeEdit.CodeEditApplication`, a class its app does not have, and an app
    /// whose plist names it exits at launch (B-77). The keys Xcode's processing adds to
    /// any plist stay.
    func test_theInfoPlistKeySettingsAreReadOnlyForAGeneratedPlist() throws {
        let emitter = try emitter()
        let app = try XCTUnwrap(emitter.project.targets.first(where: \.isApplication))
        var values = ["PRODUCT_NAME": "CodeEdit", "PRODUCT_BUNDLE_IDENTIFIER": "app.codeedit.CodeEdit",
                      "MACOSX_DEPLOYMENT_TARGET": "14.0", "GENERATE_INFOPLIST_FILE": "NO",
                      "INFOPLIST_KEY_NSPrincipalClass": "CodeEdit.CodeEditApplication"]

        let notGenerated = try TargetIdentity(target: app, settings: XcodeBuildSettings(values: values), sdk: "macosx")
            .generatedInfoPlistKeys(settings: XcodeBuildSettings(values: values))
        XCTAssertNil(notGenerated["NSPrincipalClass"])
        XCTAssertEqual(notGenerated["LSMinimumSystemVersion"] as? String, "14.0")

        values["GENERATE_INFOPLIST_FILE"] = "YES"
        let generated = try TargetIdentity(target: app, settings: XcodeBuildSettings(values: values), sdk: "macosx")
            .generatedInfoPlistKeys(settings: XcodeBuildSettings(values: values))
        XCTAssertEqual(generated["NSPrincipalClass"] as? String, "CodeEdit.CodeEditApplication")
    }

    /// Two settings can name one plist key: `X_Generation` stands for an empty `X`, and
    /// `X_iPad` for `X~ipad` a project may also write literally. Which of them the key
    /// ends up holding must not depend on `Dictionary`'s iteration order, which is seeded
    /// per process: the setting sorting last wins, the same way on every run.
    func test_twoSettingsNamingOnePlistKeyResolveTheSameWayOnEveryRun() throws {
        let emitter = try emitter()
        let app = try XCTUnwrap(emitter.project.targets.first(where: \.isApplication))
        let generated = ["UILaunchScreen", "UIApplicationShortcutItems", "UIApplicationSceneManifest"]
        let iPad = ["UIStatusBarStyle", "UIUserInterfaceStyle", "UILaunchStoryboardName"]

        var values = ["PRODUCT_NAME": "Ice Cubes", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app", "GENERATE_INFOPLIST_FILE": "YES"]
        for key in generated {
            values["INFOPLIST_KEY_\(key)_Generation"] = "YES"
            values["INFOPLIST_KEY_\(key)"] = "from the literal setting"
        }
        for key in iPad {
            values["INFOPLIST_KEY_\(key)_iPad"] = "from the _iPad setting"
            values["INFOPLIST_KEY_\(key)~ipad"] = "from the ~ipad setting"
        }
        let settings = XcodeBuildSettings(values: values)

        let keys = try TargetIdentity(target: app, settings: settings, sdk: "iphonesimulator").generatedInfoPlistKeys(settings: settings)

        for key in generated {
            XCTAssertNotNil(keys[key] as? [String: Bool], "\(key) holds what `\(key)_Generation` stands for")
        }
        for key in iPad {
            XCTAssertEqual(keys["\(key)~ipad"] as? String, "from the ~ipad setting")
        }
    }

    // MARK: - Extensions

    /// An extension the app embeds is a bundle of its own under the app's `PlugIns/`:
    /// compiled and linked as an extension, its Info.plist an `XPC!` bundle, and what it
    /// borrows from the app's folder compiled or copied with it.
    func test_embedsEachExtensionAsABundleUnderPlugIns() throws {
        let formula = try formula()
        let appex = "Ice Cubes.app/PlugIns/IceCubesShareExtension.appex"

        XCTAssertTrue(formula.contains("func compiler_IceCubesShareExtension() =\n    SwiftCompiler("), formula)
        XCTAssertTrue(formula.contains("arguments: '-application-extension', defines: 'DEBUG'"), formula)
        XCTAssertTrue(formula.contains("'Entity.swift': StaticFile(path: 'input:/repo/IceCubesApp/Shared/Entity.swift').output"), formula)
        XCTAssertTrue(formula.contains("product '\(appex)/IceCubesShareExtension' =\n    SwiftLinker("), formula)
        XCTAssertTrue(formula.contains("arguments: '-Xlinker,-e,-Xlinker,_NSExtensionMain,-Xlinker,-application_extension'"), formula)
        XCTAssertTrue(formula.contains("product '\(appex)/glass.wav' = StaticFile(path: 'input:/repo/IceCubesApp/Embeds/glass.wav').output"), formula)
        XCTAssertTrue(formula.contains("product '\(appex)/Info.plist' = infoPlist_IceCubesShareExtension().plist"), formula)
        XCTAssertTrue(formula.contains("\"CFBundlePackageType\":\"XPC!\""), formula)
    }

    func test_repositoryNamesFollowTheVendoringRule() {
        XCTAssertEqual(XcodeFormulaEmitter.repositoryName(forURL: "https://github.com/wishkit/wishkit-ios.git"), "wishkit-ios")
        XCTAssertEqual(XcodeFormulaEmitter.repositoryName(forURL: "https://github.com/RevenueCat/purchases-ios-spm"), "purchases-ios-spm")
    }

    // MARK: - Xcode's rule for a synchronized folder (B-77)

    /// A Mac app owning one synchronized folder, `App`, as the project Xcode 26.6 built to
    /// establish the rule had it: the target's own Info.plist and entitlements in the
    /// folder, an exception leaving out `Excluded.txt`, and `Explicit` named in the group's
    /// `explicitFolders`.
    static let probeProject = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            objectVersion = 77;
            objects = {
                P1 = { isa = PBXProject; buildConfigurationList = CL1; mainGroup = G1; targets = ( T1 ); developmentRegion = en; };
                G1 = { isa = PBXGroup; children = ( SG1 ); sourceTree = "<group>"; };
                CL1 = { isa = XCConfigurationList; buildConfigurations = ( C1 ); };
                C1 = { isa = XCBuildConfiguration; name = Debug; buildSettings = {
                    MACOSX_DEPLOYMENT_TARGET = 15.0;
                    SDKROOT = macosx;
                    SWIFT_VERSION = 5.0;
                }; };
                T1 = {
                    isa = PBXNativeTarget;
                    name = Probe;
                    productType = "com.apple.product-type.application";
                    productReference = PR1;
                    buildConfigurationList = CL2;
                    buildPhases = ( );
                    fileSystemSynchronizedGroups = ( SG1 );
                    packageProductDependencies = ( );
                };
                SG1 = { isa = PBXFileSystemSynchronizedRootGroup; path = App; exceptions = ( EX1 ); explicitFileTypes = { }; explicitFolders = ( Explicit ); sourceTree = "<group>"; };
                EX1 = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = ( Excluded.txt ); target = T1; };
                PR1 = { isa = PBXFileReference; explicitFileType = wrapper.application; path = Probe.app; sourceTree = BUILT_PRODUCTS_DIR; };
                CL2 = { isa = XCConfigurationList; buildConfigurations = ( C2 ); };
                C2 = { isa = XCBuildConfiguration; name = Debug; buildSettings = {
                    CODE_SIGN_ENTITLEMENTS = App/App.entitlements;
                    GENERATE_INFOPLIST_FILE = YES;
                    INFOPLIST_FILE = App/Info.plist;
                    PRODUCT_BUNDLE_IDENTIFIER = com.example.Probe;
                    PRODUCT_NAME = "$(TARGET_NAME)";
                }; };
            };
            rootObject = P1;
        }
        """

    /// What that folder held, less the hidden files Semel's push does not take, and a
    /// `.nnwtheme`, which Xcode took whole only because a NetNewsWire built on the same
    /// machine had declared the type a package. What is inside a folder taken whole is
    /// listed too, as a walk that went into it would list it, to show it is not taken
    /// again file by file.
    static let probeListing = XcodeFormulaEmitter.FolderListing(
        files: ["App.swift", "Helper.c", "Helper.h", "Header.h", "Prefix.pch", "Thing.hpp", "Thing.hh", "Thing.inc", "Thing.def",
                "module.modulemap", "Sub/Other.modulemap", "Thing.apinotes", "syms.exp",
                "Info.plist", "Data.plist", "Sub/Nested.plist", "App.entitlements", "Extra.entitlements",
                "Config.xcconfig", "README.md", "data.json", "Sub/deep.json", "Sub/Info.json", "page.html", "style.css", "script.js",
                "Dictionary.sdef", "Credits.rtf", "unknown.xyz", "Sub/noextension", "tool.sh", "tool.py", "Test.provisionprofile",
                "Template.swift.gyb", "notes.txt", "Copied.txt", "Excluded.txt", "list.xcfilelist", "Model.xcfilelist2",
                "Plan.xctestplan", "Store.storekit", "link.order", "font.ttf", "Pic.jpg", "icon.icns", "image.png",
                "Root.strings", "en.lproj/Legacy.strings", "de.lproj/Legacy.strings", "Sub/en.lproj/Nested.strings",
                "en.lproj/Readme.txt", "en.lproj/Plural.stringsdict", "Localizable.xcstrings",
                "Code.group/Inner.swift", "Dotted.Name/inner.txt",
                "Sample.bundle/inside.txt", "Pics.rtfd/TXT.rtf", "Explicit/one.txt", "Explicit/Deeper/two.txt", "Doc.docc/Doc.md"],
        folders: ["Sub", "Sub/en.lproj", "en.lproj", "de.lproj", "Code.group", "Dotted.Name", "Sample.bundle", "Pics.rtfd",
                  "Explicit", "Explicit/Deeper", "Doc.docc", "Assets.xcassets", "Empty"])

    /// What Xcode 26.6 put under `Probe.app/Contents/Resources` for that folder, each file
    /// copied (`CpResource`, `CopyPlistFile`, `CopyStringsFile`, `CopyPNGFile`) — less the
    /// target's own `Info.plist`, which it copied too, with a warning, and Semel does not.
    static let probeCopiedByXcode: Set<String> = [
        "Config.xcconfig", "Copied.txt", "Credits.rtf", "Data.plist", "Dictionary.sdef", "Info.json", "Model.xcfilelist2",
        "Nested.plist", "Pic.jpg", "Plan.xctestplan", "README.md", "Root.strings", "Store.storekit", "Template.swift.gyb",
        "Test.provisionprofile", "Thing.def", "data.json", "deep.json", "font.ttf", "icon.icns", "image.png", "inner.txt",
        "link.order", "list.xcfilelist", "noextension", "notes.txt", "page.html", "script.js", "style.css", "tool.py", "tool.sh",
        "unknown.xyz", "de.lproj/Legacy.strings", "en.lproj/Legacy.strings", "en.lproj/Nested.strings",
        "en.lproj/Plural.stringsdict", "en.lproj/Readme.txt",
    ]

    private func probeBundle() throws -> String {
        let project = try XcodeProject(pbxproj: Data(Self.probeProject.utf8))
        let macBuild = XcodeFormulaEmitter.Build(root: "input:/probe", projectFolder: "input:/probe", configuration: "Debug", sdk: "macosx")
        let emitter = XcodeFormulaEmitter(project: project, build: macBuild)
        let formula = try emitter.formula(
            for: try XCTUnwrap(emitter.project.applications.first),
            settings: { target in
                try XcodeBuildSettings.resolve(project: project, target: target, configuration: "Debug", sdk: "macosx",
                                               xcconfig: { _ in nil }, extra: ["TARGET_NAME": target.name])
            },
            listing: { $0 == "input:/probe/App" ? Self.probeListing : nil })
        return try block("func bundle_Probe() = TreeMerger(input: [", in: formula)
    }

    private func matches(of pattern: String, in text: String) throws -> Set<String> {
        let expression = try NSRegularExpression(pattern: pattern)
        return Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    /// The files of a synchronized folder the bundle copies are the ones Xcode copied, at
    /// the places it put them: every one flattened to its name — `Sub/deep.json` is
    /// `deep.json`, a dotted folder's `inner.txt` too — but a localized one, which keeps
    /// its `.lproj`; a plist, a Markdown file, an xcconfig, a provisioning profile, a
    /// `.def` and a file of no known type among them; no source, header, module map,
    /// entitlements file, exception, or file inside a folder taken whole.
    func test_copiesWhatXcodeCopiesFromASynchronizedFolderWhereXcodePutsIt() throws {
        let bundle = try probeBundle()

        let copied = try matches(of: "'Contents/Resources/([^']+)': StaticFile", in: bundle)
        XCTAssertEqual(copied, Self.probeCopiedByXcode,
                       "extra: \(copied.subtracting(Self.probeCopiedByXcode).sorted()), missing: \(Self.probeCopiedByXcode.subtracting(copied).sorted())")
        XCTAssertTrue(bundle.contains("'Contents/Resources/deep.json': StaticFile(path: 'input:/probe/App/Sub/deep.json').output"), bundle)
        XCTAssertTrue(bundle.contains("'Contents/Resources/en.lproj/Nested.strings': StaticFile(path: 'input:/probe/App/Sub/en.lproj/Nested.strings').output"),
                      bundle)
    }

    /// A bundle, a rich text document and a folder the group names in `explicitFolders`
    /// are each one item, copied whole under their own names with what they hold laid out
    /// as it is; the catalog is compiled and the string catalog too, and a documentation
    /// catalog is neither copied nor walked for files.
    func test_aFolderXcodeTakesAsOneItemIsCopiedWhole() throws {
        let bundle = try probeBundle()

        let whole = try matches(of: "FolderTreeBuilder\\(under: '([^']+)'", in: bundle)
        XCTAssertEqual(whole, ["Explicit", "Pics.rtfd", "Sample.bundle"], bundle)
        XCTAssertTrue(bundle.contains("FolderTreeBuilder(under: 'Explicit', folder: ['folder': Folder(path: 'input:/probe/App/Explicit').manifest]).files"),
                      bundle)
        XCTAssertTrue(bundle.contains("'assets': assets_Probe().files"), bundle)
        XCTAssertTrue(bundle.contains("'strings0': strings_Probe_0().files"), bundle)
        XCTAssertFalse(bundle.contains("Doc.md"), bundle)
    }

    /// The rule file by file, as Xcode 26.6 sorted the probe's folder.
    func test_eachFileOfASynchronizedFolderIsSortedByXcodesRule() {
        let copied = ["notes.txt", "data.json", "page.html", "style.css", "script.js", "Dictionary.sdef", "Credits.rtf",
                      "Data.plist", "README.md", "Config.xcconfig", "Test.provisionprofile", "Template.swift.gyb", "unknown.xyz",
                      "noextension", "Thing.def", "Plan.xctestplan", "Store.storekit", "list.xcfilelist", "icon.icns", "image.png",
                      "Root.strings", "Info.plist"]
        for name in copied {
            XCTAssertEqual(XcodeFormulaEmitter.resource(at: "Sub/\(name)"), .copied(bundlePath: name), name)
        }
        let never = ["App.swift", "Helper.c", "Greeter.m", "Cruncher.mm", "Helper.h", "Thing.hpp", "Thing.hh", "Prefix.pch",
                     "module.modulemap", "Thing.apinotes", "App.entitlements", "syms.exp", "Thing.inc", "Shader.metal",
                     ".DS_Store", "Assets.xcassets/Contents.json"]
        for name in never {
            XCTAssertEqual(XcodeFormulaEmitter.resource(at: name), .ignored, name)
        }
        XCTAssertEqual(XcodeFormulaEmitter.resource(at: "Sub/en.lproj/Plural.stringsdict"), .copied(bundlePath: "en.lproj/Plural.stringsdict"))
        XCTAssertEqual(XcodeFormulaEmitter.resource(at: "Localizable.xcstrings"), .stringCatalog)
        XCTAssertEqual(XcodeFormulaEmitter.resource(at: "Shader.metal", listedInResourcesPhase: true), .copied(bundlePath: "Shader.metal"),
                       "a resources phase copies what it lists")

        XCTAssertEqual(XcodeFormulaEmitter.folderRole(at: "Sub"), .group)
        XCTAssertEqual(XcodeFormulaEmitter.folderRole(at: "Dotted.Name"), .group)
        XCTAssertEqual(XcodeFormulaEmitter.folderRole(at: "Base.lproj"), .group)
        XCTAssertEqual(XcodeFormulaEmitter.folderRole(at: "Resources/Assets.xcassets"), .catalog)
        XCTAssertEqual(XcodeFormulaEmitter.folderRole(at: "AppIcon.icon"), .catalog)
        XCTAssertEqual(XcodeFormulaEmitter.folderRole(at: "Sub/Sample.bundle"), .copiedWhole(bundlePath: "Sample.bundle"))
        XCTAssertEqual(XcodeFormulaEmitter.folderRole(at: "Sub/en.lproj/Help.rtfd"), .copiedWhole(bundlePath: "en.lproj/Help.rtfd"))
        XCTAssertEqual(XcodeFormulaEmitter.folderRole(at: "Sub/Explicit", explicitFolders: ["Sub/Explicit"]), .copiedWhole(bundlePath: "Explicit"))
        XCTAssertEqual(XcodeFormulaEmitter.folderRole(at: "Model.xcdatamodeld"), .notBuilt)
        XCTAssertEqual(XcodeFormulaEmitter.folderRole(at: "Guide.docc"), .notBuilt)
    }

    /// On iOS the same files land at the bundle's root, which is where the target's own
    /// Info.plist would have collided with the one the bundle is built with — Xcode fails
    /// there on "Multiple commands produce …/Info.plist" — so it is the plist's base and
    /// nothing else.
    func test_theTargetsOwnInfoPlistIsTheBaseAndNotAResource() throws {
        let project = try XcodeProject(pbxproj: Data(Self.probeProject.utf8))
        let iosBuild = XcodeFormulaEmitter.Build(root: "input:/probe", projectFolder: "input:/probe", configuration: "Debug", sdk: "iphonesimulator")
        let emitter = XcodeFormulaEmitter(project: project, build: iosBuild)
        let formula = try emitter.formula(
            for: try XCTUnwrap(emitter.project.applications.first),
            settings: { target in
                try XcodeBuildSettings.resolve(project: project, target: target, configuration: "Debug", sdk: "iphonesimulator",
                                               xcconfig: { _ in nil }, extra: ["TARGET_NAME": target.name])
            },
            listing: { $0 == "input:/probe/App" ? Self.probeListing : nil })

        XCTAssertEqual(formula.components(separatedBy: "product 'Probe.app/Info.plist' =").count - 1, 1, formula)
        XCTAssertTrue(formula.contains("base: ['base': StaticFile(path: 'input:/probe/App/Info.plist').output]"), formula)
        XCTAssertTrue(formula.contains("product 'Probe.app/Data.plist' = StaticFile(path: 'input:/probe/App/Data.plist').output"), formula)
        XCTAssertTrue(formula.contains("product 'Probe.app/deep.json' = StaticFile(path: 'input:/probe/App/Sub/deep.json').output"), formula)
        XCTAssertFalse(formula.contains("App.entitlements' = StaticFile"), formula)
    }

    // MARK: - What the second probe established (B-77)

    /// What the second probe's folder held (`XcodeProjectTests.exceptionProbe`).
    static let exceptionProbeListing = XcodeFormulaEmitter.FolderListing(
        files: ["App.swift", "Flagged.swift", "Plain/Under.swift", "Helper.c", "Helper.h", "Bridge.h", "Copied.txt", "Support.txt"],
        folders: ["Plain"])

    private func exceptionProbeFormula(sdk: String = "macosx") throws -> String {
        let project = try XcodeProject(pbxproj: Data(XcodeProjectTests.exceptionProbe.utf8))
        let emitter = XcodeFormulaEmitter(project: project,
                                          build: .init(root: "input:/probe", projectFolder: "input:/probe", configuration: "Debug", sdk: sdk))
        return try emitter.formula(
            for: try XCTUnwrap(emitter.project.applications.first),
            settings: { target in
                try XcodeBuildSettings.resolve(project: project, target: target, configuration: "Debug", sdk: sdk,
                                               xcconfig: { _ in nil }, extra: ["TARGET_NAME": target.name])
            },
            listing: { $0 == "input:/probe/App" ? Self.exceptionProbeListing : nil })
    }

    /// The bundle the probe's Mac build writes holds what Xcode's held: the plist, the
    /// executable, `PkgInfo` from the plist, both copied files where their own type puts
    /// them — the resources — and again where the copy-files phase naming them says,
    /// `Contents/Resources/Extra/` and `Contents/SharedSupport/`.
    func test_aCopyFilesPhasesExceptionCopiesTheFileThereAsWell() throws {
        let bundle = try block("func bundle_Probe() = TreeMerger(input: [", in: try exceptionProbeFormula())

        let placed = try matches(of: "'(Contents/[^']+)': ", in: bundle).filter { $0 != "Contents/Resources" }
        XCTAssertEqual(placed, ["Contents/Info.plist", "Contents/MacOS/Probe", "Contents/PkgInfo",
                                "Contents/Resources/Copied.txt", "Contents/Resources/Extra/Copied.txt",
                                "Contents/Resources/Support.txt", "Contents/SharedSupport/Support.txt"], bundle)
        XCTAssertTrue(bundle.contains("'Contents/Resources/Extra/Copied.txt': StaticFile(path: 'input:/probe/App/Copied.txt').output"), bundle)
        XCTAssertTrue(bundle.contains("'Contents/SharedSupport/Support.txt': StaticFile(path: 'input:/probe/App/Support.txt').output"), bundle)
        XCTAssertTrue(bundle.contains("'Contents/PkgInfo': infoPlist_Probe().pkgInfo"), bundle)
    }

    /// Each destination a copy-files phase names, as the bundle lays it out; one outside
    /// the bundle has no place in it.
    func test_aCopyFilesDestinationIsTheBundlesFolderForIt() {
        let mac = XcodeFormulaEmitter.BundleLayout(sdk: "macosx")
        let iOS = XcodeFormulaEmitter.BundleLayout(sdk: "iphonesimulator")
        func folder(_ layout: XcodeFormulaEmitter.BundleLayout, _ spec: Int, _ path: String = "") -> String? {
            layout.folder(forCopyDestination: .init(subfolderSpec: spec, path: path))
        }

        XCTAssertEqual(folder(mac, 7, "Extra"), "Contents/Resources/Extra")
        XCTAssertEqual(folder(mac, 12), "Contents/SharedSupport")
        XCTAssertEqual(folder(mac, 10), "Contents/Frameworks")
        XCTAssertEqual(folder(mac, 13), "Contents/PlugIns")
        XCTAssertEqual(folder(mac, 6), "Contents/MacOS")
        XCTAssertEqual(folder(mac, 1, "Extras"), "Extras")
        XCTAssertEqual(folder(iOS, 7), "")
        XCTAssertEqual(folder(iOS, 7, "Extra/"), "Extra")
        XCTAssertEqual(folder(iOS, 10), "Frameworks")
        XCTAssertNil(folder(mac, 16))
        XCTAssertNil(folder(mac, 16, "Extras"), "the products folder itself is outside the bundle")
        XCTAssertNil(folder(mac, 0, "/usr/local"))
        // The products folder with a path naming one of the bundle's folders by its setting
        // is that folder: CodeEdit's extension point, `$(EXTENSIONS_FOLDER_PATH)` (B-77).
        XCTAssertEqual(folder(mac, 16, "$(EXTENSIONS_FOLDER_PATH)"), "Contents/Extensions")
        XCTAssertEqual(folder(iOS, 16, "$(EXTENSIONS_FOLDER_PATH)"), "Extensions")
        XCTAssertEqual(folder(mac, 16, "$(CONTENTS_FOLDER_PATH)/Library/LoginItems"), "Contents/Library/LoginItems")
        XCTAssertEqual(folder(mac, 16, "$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Extra"), "Contents/Resources/Extra")
    }

    /// A folder a copy-files phase names is copied whole, and one copied into a folder the
    /// bundle already merges trees into joins that tree.
    func test_aFolderACopyFilesPhaseNamesIsCopiedWhole() throws {
        let pbxproj = XcodeProjectTests.exceptionProbe.replacingOccurrences(of: "membershipExceptions = ( Copied.txt );",
                                                                            with: "membershipExceptions = ( Plain );")
            .replacingOccurrences(of: "dstPath = Extra; dstSubfolderSpec = 7;", with: "dstPath = \"\"; dstSubfolderSpec = 7;")
        let project = try XcodeProject(pbxproj: Data(pbxproj.utf8))
        let emitter = XcodeFormulaEmitter(project: project,
                                          build: .init(root: "input:/probe", projectFolder: "input:/probe", configuration: "Debug", sdk: "macosx"))
        let formula = try emitter.formula(
            for: try XCTUnwrap(emitter.project.applications.first),
            settings: { target in
                try XcodeBuildSettings.resolve(project: project, target: target, configuration: "Debug", sdk: "macosx",
                                               xcconfig: { _ in nil }, extra: ["TARGET_NAME": target.name])
            },
            listing: { $0 == "input:/probe/App" ? Self.exceptionProbeListing : nil })
        let bundle = try block("func bundle_Probe() = TreeMerger(input: [", in: formula)

        XCTAssertEqual(bundle.components(separatedBy: "    'Contents/Resources': TreeMerger(").count - 1, 1, bundle)
        XCTAssertTrue(bundle.contains("'copied0': FolderTreeBuilder(under: 'Plain', folder: ['folder': Folder(path: 'input:/probe/App/Plain').manifest]).files"),
                      bundle)
    }

    /// A C source's own flags reach the clang nodes that preprocess and compile it, after
    /// the target's `OTHER_CFLAGS`, which every C-family source of the target gets; a Swift
    /// source's reach nothing, as in Xcode.
    func test_aSourcesOwnFlagsReachClangAfterTheTargetsAndASwiftSourcesReachNothing() throws {
        let formula = try exceptionProbeFormula()

        let shared = try block("func preprocess_Probe(path) =", in: formula)
        XCTAssertTrue(shared.contains("SettingsLiteral(arguments: '-DPROBE_OTHER_C', headerMapProduct: 'Probe', modules: 'true', target: 'arm64-apple-macosx15.0')"), shared)
        let own = try block("func preprocess_Probe_0(path) =", in: formula)
        XCTAssertTrue(own.contains("SettingsLiteral(arguments: '-DPROBE_OTHER_C,-DPROBE_FLAG=7', headerMapProduct: 'Probe', modules: 'true', target: 'arm64-apple-macosx15.0')"), own)
        XCTAssertTrue(formula.contains("'input:/probe/App/Helper.c.o': ClangCompiler(configuration: ['config': ConfigMerger(base: ['settings': "
                                       + "ConfigFilter(prefix: 'clang.compiler', "), formula)
        XCTAssertTrue(formula.contains("SettingsLiteral(arguments: '-DPROBE_OTHER_C,-DPROBE_FLAG=7', modules: 'true', target: 'arm64-apple-macosx15.0')"
                                       + ".output]).output], input: ['input:/probe/App/Helper.c.p': preprocess_Probe_0(path: 'input:/probe/App/Helper.c')]).output"),
                      formula)
        XCTAssertFalse(formula.contains("PROBE_SWIFT_FILE_FLAG"), formula)
    }

    /// A file forced in ahead of the source is the preprocessor's alone: the compiler reads
    /// text that already holds it.
    func test_aForcedIncludeIsThePreprocessorsAlone() {
        XCTAssertEqual(XcodeFormulaEmitter.compileStageFlags(["-include", "Prefix.h", "-DX", "-imacrosMacros.h", "-Wall"]), ["-DX", "-Wall"])
    }

    /// `Plain` is among the owner's exceptions and a plain folder, so what is under it is
    /// compiled — the compiler is not told to leave it out.
    func test_anExceptionNamingAPlainFolderLeavesItsSourcesCompiled() throws {
        let compiler = try block("func compiler_Probe() =", in: try exceptionProbeFormula())

        XCTAssertFalse(compiler.contains("excludedPaths"), compiler)
    }

    /// The probe's language settings reach the compiler as Xcode passed them: the
    /// condition, `OTHER_SWIFT_FLAGS`, targeted strict concurrency and bare-slash regex
    /// literals below Swift 6, the five features Approachable Concurrency stands for with
    /// `ExistentialAny` in Xcode's order, and `DebugDescriptionMacro`.
    func test_theLanguageSettingsReachTheSwiftCompilerAsXcodePassesThem() throws {
        let compiler = try block("func compiler_Probe() =", in: try exceptionProbeFormula())

        XCTAssertTrue(compiler.contains("SettingsLiteral(defines: 'PROBE_CONDITION', experimentalFeatures: 'DebugDescriptionMacro', "
                                        + "languageMode: '5', moduleName: 'Probe', objectiveCHeaderName: 'Probe-Swift.h', target: 'arm64-apple-macosx15.0', "
                                        + "unsafeFlags: '[\"-DPROBE_OTHER_SWIFT\",\"-strict-concurrency=targeted\",\"-enable-bare-slash-regex\"]', "
                                        + "upcomingFeatures: 'DisableOutwardActorInference,InferSendableFromCaptures,GlobalActorIsolatedTypesUsability,"
                                        + "ExistentialAny,InferIsolatedConformances,NonisolatedNonsendingByDefault')"), compiler)
    }

    /// The probe asks for the hardened runtime, and its signer is told so.
    func test_aBundleAskingForTheHardenedRuntimeIsSignedWithIt() throws {
        let formula = try exceptionProbeFormula()

        let signer = try block("func signed_Probe() =\n    CodeSigner(", in: formula)
        XCTAssertTrue(signer.contains("SettingsLiteral(hardenedRuntime: 'true', identity: '-')"), signer)
        XCTAssertFalse(try macFormula().contains("hardenedRuntime"), "the fixture does not ask for it")
    }

    /// An iOS application gets its `PkgInfo` at the bundle's root, beside its plist.
    func test_anIOSApplicationHasAPkgInfoBesideItsPlist() throws {
        let formula = try exceptionProbeFormula(sdk: "iphonesimulator")

        XCTAssertTrue(formula.contains("product 'Probe.app/PkgInfo' = infoPlist_Probe().pkgInfo"), formula)
    }

    // MARK: - Config namespaces

    /// `prepare` writes a config block for each namespace the converter declares and no
    /// other, so the declaration has to cover every prefix the formula selects.
    func test_theDeclaredConfigNamespacesCoverEveryPrefixTheFormulaSelects() throws {
        let selected = try configFilterPrefixes(in: formula())

        XCTAssertFalse(selected.isEmpty)
        XCTAssertTrue(selected.isSubset(of: XcodeProjectConverter.configNamespaces),
                      "selected \(selected.sorted()), declared \(XcodeProjectConverter.configNamespaces)")
    }

    private func configFilterPrefixes(in formula: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: "ConfigFilter\\(prefix: '([^']+)'")
        let matches = pattern.matches(in: formula, range: NSRange(formula.startIndex..., in: formula))
        return Set(matches.compactMap { Range($0.range(at: 1), in: formula).map { String(formula[$0]) } })
    }
}
