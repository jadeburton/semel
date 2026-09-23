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
                            folders: ["Views", "Fonts", "Embeds", "Resources", "Assets.xcassets"])) throws -> String {
        let emitter = try emitter()
        return try emitter.formula(
            settings: { target in
                try XcodeBuildSettings.resolve(project: emitter.project, target: target, configuration: "Debug", sdk: "iphonesimulator",
                                               xcconfig: { _ in "BUNDLE_ID_PREFIX = com.example" },
                                               extra: ["TARGET_NAME": target.name])
            },
            listing: { $0 == "input:/repo/IceCubesApp" ? listing : nil })
    }

    // MARK: - Packages

    /// Every local package the project references, and each remote one where the
    /// vendoring rule puts it, under the one build root.
    func test_includesEveryPackageTheProjectReferences() throws {
        let formula = try formula()

        XCTAssertTrue(formula.contains("include SwiftFormulaConverter(path: 'input:/repo/Packages/Timeline', root: 'input:/repo').formula"), formula)
        XCTAssertTrue(formula.contains("include SwiftFormulaConverter(path: 'input:/repo/Packages/Models', root: 'input:/repo').formula"), formula)
        XCTAssertTrue(formula.contains("include SwiftFormulaConverter(path: 'input:/repo/Dependencies/keychain-swift', root: 'input:/repo').formula"), formula)
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
        XCTAssertTrue(formula.contains("ConfigFilter(prefix: 'swift.compiler', input: ['config': StaticFile(path: 'input:/repo/semel.config').output])"), formula)
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
        XCTAssertTrue(formula.contains("product 'Ice Cubes.app/' = TreeMerger(input: ['assets': assets_IceCubesApp().files, 'strings0': strings_IceCubesApp_0().files]).files"), formula)
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
        XCTAssertTrue(formula.contains("PRODUCT_NAME: 'Ice Cubes'"), formula)
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
