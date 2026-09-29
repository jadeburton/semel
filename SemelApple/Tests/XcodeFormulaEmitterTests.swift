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
                                       + "        'Shared/Sources/Util.swift': StaticFile(path: 'input:/repo/Shared/Sources/Util.swift').output\n"
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

    /// A listed source that is neither Swift nor C-family is a build this converter cannot
    /// write yet, and it says which files rather than compiling around them.
    func test_aListedSourceThatIsNotSwiftOrCFamilyIsRefusedByName() throws {
        let pbxproj = XcodeProjectTests.groupedFixture
            .replacingOccurrences(of: "path = Util.swift;", with: "path = Util.metal;")
        XCTAssertThrowsError(try groupedFormula(pbxproj: pbxproj)) { error in
            XCTAssertEqual("\(error)", "Food Truck: sources that are not Swift are not compiled yet: Shared/Sources/Util.metal")
        }
    }

    /// A listed Objective-C source is compiled through clang, over the folder it sits in
    /// as its header folder, and linked beside the Swift.
    func test_aListedObjectiveCSourceIsCompiledAndLinked() throws {
        let pbxproj = XcodeProjectTests.groupedFixture
            .replacingOccurrences(of: "path = Util.swift;", with: "path = Util.m;")
        let formula = try groupedFormula(pbxproj: pbxproj)

        XCTAssertTrue(formula.contains("func preprocess_Food_Truck(path) =\n    ClangPreprocessor("), formula)
        XCTAssertTrue(formula.contains("'input:/repo/Shared/Sources': Folder(path: 'input:/repo/Shared/Sources').manifest"), formula)
        XCTAssertTrue(formula.contains("'input:/repo/Shared/Sources/Util.m.o': ClangCompiler("), formula)
        XCTAssertTrue(formula.contains("input: ['input:/repo/Shared/Sources/Util.m.p': preprocess_Food_Truck(path: 'input:/repo/Shared/Sources/Util.m')]).output"),
                      formula)
    }

    // MARK: - A macOS bundle (B-77)

    /// The fixture for `macosx`, with `extra` laid over every target's settings.
    private func macFormula(extra: [String: String] = [:],
                            listing: @escaping (String) -> XcodeFormulaEmitter.FolderListing? = { _ in nil }) throws -> String {
        let macBuild = XcodeFormulaEmitter.Build(root: "input:/repo", projectFolder: "input:/repo", configuration: "Debug", sdk: "macosx")
        let emitter = XcodeFormulaEmitter(project: try XcodeProject(pbxproj: Data(XcodeProjectTests.fixture.utf8)), build: macBuild)
        return try emitter.formula(
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
        XCTAssertTrue(bundle.contains("        'Contents/Info.plist': InfoPlistBuilder(\n"), bundle)
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
    /// at run time under `Contents/Frameworks`, and embedded there — named for every product,
    /// since `frameworks_P()` is empty for one that reaches none.
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
                                      + "        'KeychainSwift': frameworks_KeychainSwift().files,\n"
                                      + "        'Timeline': frameworks_Timeline().files\n    ]).files"), bundle)
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

        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/Frameworks/' = TreeMerger(input: ["), formula)
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
        XCTAssertTrue(formula.contains("arguments: '-D,DEBUG,-D,EXTRA'"), formula)
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
        XCTAssertTrue(formula.contains("override: ['literals': SettingsLiteral(arguments: '-D,DEBUG,-D,EXTRA', "), formula)
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
        XCTAssertTrue(formula.contains("SettingsLiteral(cStandard: 'gnu11', defines: 'DEBUG=1,FEATURE', modules: 'true', objectiveCARC: 'true', "
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
                                       + "preprocess_IceCubesApp(path: 'input:/repo/IceCubesApp/Legacy/Greeter.m')]).output"), formula)
        XCTAssertTrue(formula.contains("'IceCubesApp C++': SettingsLiteral(cxxRuntime: 'true').output"), formula)
        XCTAssertFalse(formula.contains("product 'Ice Cubes.app/Greeter.h'"), "a header is no resource: \(formula)")
    }

    /// The bridging header reaches the Swift compiler by itself, with the folder's other
    /// headers as the tree it imports from — `headers_<Target>()`, the shape a package's C
    /// target hands a Swift importer — and the macros its C-family sources are
    /// preprocessed with, as Xcode tells the importer.
    func test_theBridgingHeaderReachesTheSwiftCompilerWithTheTargetsHeaders() throws {
        let formula = try formula(listing: objectiveCListing, xcconfig: objectiveCSettings)

        XCTAssertTrue(formula.contains("func headers_IceCubesApp() =\n    TreeBuilder(input: [\n"
                                       + "        'IceCubesApp/Legacy/Greeter.h': StaticFile(path: 'input:/repo/IceCubesApp/Legacy/Greeter.h').output,\n"
                                       + "        'IceCubesApp/Legacy/Private/Secret.h': StaticFile(path: 'input:/repo/IceCubesApp/Legacy/Private/Secret.h').output\n"
                                       + "    ]).files"), formula)
        XCTAssertTrue(formula.contains(",\n        bridgingHeader: ['IceCubesApp/App-Bridging-Header.h': "
                                       + "StaticFile(path: 'input:/repo/IceCubesApp/App-Bridging-Header.h').output],\n"
                                       + "        headerTrees: ['IceCubesApp': headers_IceCubesApp().files]\n    )"), formula)
        XCTAssertTrue(formula.contains("arguments: '-D,DEBUG,-D,EXTRA,-Xcc,-DDEBUG=1,-Xcc,-DFEATURE'"), formula)
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

    /// A file that is neither source nor compiled is copied into the bundle root, as
    /// Xcode flattens a synchronized folder; an exception is not; a source is not.
    func test_copiesPlainResourcesFlatAndLeavesOutExceptionsAndSources() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/Mono.ttf' = StaticFile(path: 'input:/repo/IceCubesApp/Fonts/Mono.ttf').output"), formula)
        XCTAssertFalse(formula.contains("product 'Ice Cubes.app/glass.wav'"), "an exception is another target's: \(formula)")
        XCTAssertFalse(formula.contains("product 'Ice Cubes.app/App.swift'"), formula)
        XCTAssertFalse(formula.contains("product 'Ice Cubes.app/README.md'"), formula)
        XCTAssertFalse(formula.contains("product 'Ice Cubes.app/Contents.json'"), "inside a catalog: \(formula)")
    }

    // MARK: - Info.plist

    func test_buildsTheInfoPlistFromTheFileTheGeneratedKeysAndActoolsPartial() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/Info.plist' =\n    InfoPlistBuilder("), formula)
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
            "IPHONEOS_DEPLOYMENT_TARGET": "18.0", "TARGETED_DEVICE_FAMILY": "1,2,7",
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

    /// Two settings can name one plist key: `X_Generation` stands for an empty `X`, and
    /// `X_iPad` for `X~ipad` a project may also write literally. Which of them the key
    /// ends up holding must not depend on `Dictionary`'s iteration order, which is seeded
    /// per process: the setting sorting last wins, the same way on every run.
    func test_twoSettingsNamingOnePlistKeyResolveTheSameWayOnEveryRun() throws {
        let emitter = try emitter()
        let app = try XCTUnwrap(emitter.project.targets.first(where: \.isApplication))
        let generated = ["UILaunchScreen", "UIApplicationShortcutItems", "UIApplicationSceneManifest"]
        let iPad = ["UIStatusBarStyle", "UIUserInterfaceStyle", "UILaunchStoryboardName"]

        var values = ["PRODUCT_NAME": "Ice Cubes", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app"]
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
        XCTAssertTrue(formula.contains("arguments: '-D,DEBUG,-application-extension'"), formula)
        XCTAssertTrue(formula.contains("'Entity.swift': StaticFile(path: 'input:/repo/IceCubesApp/Shared/Entity.swift').output"), formula)
        XCTAssertTrue(formula.contains("product '\(appex)/IceCubesShareExtension' =\n    SwiftLinker("), formula)
        XCTAssertTrue(formula.contains("arguments: '-Xlinker,-e,-Xlinker,_NSExtensionMain,-Xlinker,-application_extension'"), formula)
        XCTAssertTrue(formula.contains("product '\(appex)/glass.wav' = StaticFile(path: 'input:/repo/IceCubesApp/Embeds/glass.wav').output"), formula)
        XCTAssertTrue(formula.contains("product '\(appex)/Info.plist' =\n    InfoPlistBuilder("), formula)
        XCTAssertTrue(formula.contains("\"CFBundlePackageType\":\"XPC!\""), formula)
    }

    func test_repositoryNamesFollowTheVendoringRule() {
        XCTAssertEqual(XcodeFormulaEmitter.repositoryName(forURL: "https://github.com/wishkit/wishkit-ios.git"), "wishkit-ios")
        XCTAssertEqual(XcodeFormulaEmitter.repositoryName(forURL: "https://github.com/RevenueCat/purchases-ios-spm"), "purchases-ios-spm")
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
