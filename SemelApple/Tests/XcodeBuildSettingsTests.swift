//
//  XcodeBuildSettingsTests.swift
//  SemelAppleTests
//
//  Settings evaluated the way Xcode layers them (B-77), pinned on NetNewsWire's own files:
//  `Fixtures/NetNewsWire` holds its project file and its `xcconfig` folder as they are at
//  b4361413fc1850110f9f42652f0f84e7a51e9d64, under its MIT licence, and the Mac app's and
//  Mac extensions' `Info.plist` files, which name the settings. Beside them, for the
//  tests of what the app compiles (B-77): its Objective-C and bridging header, one xib,
//  the shared scheme with its pre-action, the script that runs, and the gyb template it
//  runs on. Nearly every setting
//  that project has lives in those files — includes three deep, `$(inherited)` inside one
//  file's chain, SDK conditions, `#include?` of a developer's file outside the clone — so
//  what it evaluates to is the answer to whether the layering is Xcode's.
//
//  The smaller settings tests beside the project reader are in `XcodeProjectTests`.
//

@testable import SemelApple
import XCTest

final class XcodeBuildSettingsTests: XCTestCase {

    /// NetNewsWire's project folder, as far as the fixture copies it.
    static var netNewsWire: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/NetNewsWire", isDirectory: true)
    }

    private static var netNewsWireProject: URL {
        netNewsWire.appendingPathComponent("NetNewsWire.xcodeproj", isDirectory: true)
    }

    private func project() throws -> XcodeProject {
        try XcodeProject(pbxproj: try Data(contentsOf: Self.netNewsWireProject.appendingPathComponent("project.pbxproj")))
    }

    /// One NetNewsWire target's settings, its files read from the fixture as `prepare`
    /// reads them from a clone.
    private func settings(of targetName: String, configuration: String = "Debug", sdk: String = "macosx") throws -> XcodeBuildSettings {
        let project = try project()
        let target = try XCTUnwrap(project.targets.first { $0.name == targetName })
        let expansions = try XcodeProjectFacts.expansions(of: project.xcconfigPaths(for: target, configuration: configuration),
                                                          in: Self.netNewsWire)
        return try XcodeBuildSettings.resolve(project: project, target: target, configuration: configuration, sdk: sdk,
                                              xcconfig: { expansions[$0]?.assignments },
                                              extra: ["TARGET_NAME": target.name])
    }

    private func xcconfig(_ relativePath: String) throws -> Xcconfig {
        Xcconfig(parsing: try String(contentsOf: Self.netNewsWire.appendingPathComponent(relativePath), encoding: .utf8))
    }

    // MARK: - Reading one file

    /// The includes stay where they are written, among the assignments: their place is
    /// what `$(inherited)` and overriding are measured against.
    func test_readsIncludesAndAssignmentsInTheOrderWritten() throws {
        let lines = try xcconfig("xcconfig/NetNewsWire_iOSapp_target.xcconfig").lines

        XCTAssertEqual(Array(lines.prefix(4)), [
            .include(path: "../../SharedXcodeSettings/ProjectSettings.xcconfig", isOptional: true),
            .include(path: "./common/NetNewsWire_codesigning_common.xcconfig", isOptional: false),
            .include(path: "./common/NetNewsWire_ios_target_common.xcconfig", isOptional: false),
            .assignment(XcodeSettingAssignment(name: "LD_RUNPATH_SEARCH_PATHS", value: "$(inherited) @executable_path/Frameworks")),
        ])
    }

    /// NetNewsWire ends some values with `;` and comments out others; an empty value is
    /// still an assignment, which is how a release build says it has no bundle suffix.
    func test_dropsCommentsAndATrailingSemicolonAndKeepsAnEmptyValue() throws {
        let parsed = Xcconfig.assignments("""
            // comment
            SDKROOT = macosx;
            //SDKROOT = iphoneos
            DEVELOPMENT_TEAM = M8L2WTLA8W // the team
            BUNDLE_ID_SUFFIX =
            not a setting
            """)

        XCTAssertEqual(parsed, [XcodeSettingAssignment(name: "SDKROOT", value: "macosx"),
                                XcodeSettingAssignment(name: "DEVELOPMENT_TEAM", value: "M8L2WTLA8W"),
                                XcodeSettingAssignment(name: "BUNDLE_ID_SUFFIX", value: "")])
    }

    /// A condition per bracket, or several in one bracket; both are Xcode's syntax.
    func test_readsConditionsInEitherForm() {
        let separate = XcodeSettingAssignment(key: "CODE_SIGN_IDENTITY[sdk=iphoneos*][config=Release]", value: "iPhone Distribution")
        let together = XcodeSettingAssignment(key: "CODE_SIGN_IDENTITY[sdk=iphoneos*,config=Release]", value: "iPhone Distribution")
        let expected = [XcodeSettingCondition(parameter: "sdk", pattern: "iphoneos*"),
                        XcodeSettingCondition(parameter: "config", pattern: "Release")]

        XCTAssertEqual(separate?.conditions, expected)
        XCTAssertEqual(together?.conditions, expected)
        XCTAssertEqual(separate?.name, "CODE_SIGN_IDENTITY")
        XCTAssertNil(XcodeSettingAssignment(key: "BROKEN[sdk=iphoneos*", value: ""), "a bracket that does not close")
        XCTAssertNil(XcodeSettingAssignment(key: "NOT A NAME", value: ""))
    }

    func test_aConditionHoldsWhenEveryPatternMatches() throws {
        let debugMac = XcodeSettingContext(sdk: "macosx", configuration: "Debug")
        let assignment = try XCTUnwrap(XcodeSettingAssignment(key: "KEY[sdk=mac*][config=Deb*][arch=*]", value: ""))

        XCTAssertTrue(assignment.applies(in: debugMac))
        XCTAssertFalse(assignment.applies(in: XcodeSettingContext(sdk: "macosx", configuration: "Release")))
        XCTAssertFalse(assignment.applies(in: XcodeSettingContext(sdk: "iphonesimulator", configuration: "Debug")))
        XCTAssertFalse(try XCTUnwrap(XcodeSettingAssignment(key: "KEY[dialect=swift]", value: "")).applies(in: debugMac),
                       "a condition on what differs per source file is not one the target's settings can meet")
        XCTAssertTrue(XcodeSettingCondition.glob("a*b*c", matches: "aXbYc"))
        XCTAssertFalse(XcodeSettingCondition.glob("ab*ab", matches: "ab"))
    }

    // MARK: - Following includes

    /// NetNewsWire's Mac target file, followed on disk: each include beside the file
    /// naming it, three deep, and the developer's own signing file looked for outside the
    /// clone — beside the including file, then under the project's folder — and, being
    /// `#include?`, not missed.
    func test_followsNetNewsWiresIncludesBesideTheFileNamingThem() throws {
        let expansion = try XCTUnwrap(try XcodeProjectFacts.expansions(of: ["xcconfig/NetNewsWire_macapp_target.xcconfig"],
                                                                       in: Self.netNewsWire)["xcconfig/NetNewsWire_macapp_target.xcconfig"])

        XCTAssertEqual(expansion.files, [
            "xcconfig/NetNewsWire_macapp_target.xcconfig",
            "xcconfig/common/NetNewsWire_codesigning_common.xcconfig",
            "../SharedXcodeSettings/DeveloperSettings.xcconfig",
            "../../../SharedXcodeSettings/DeveloperSettings.xcconfig",
            "xcconfig/common/NetNewsWire_macapp_target_common.xcconfig",
            "xcconfig/common/NetNewsWire_mac_target_common.xcconfig",
            "xcconfig/common/NetNewsWire_version.xcconfig",
        ])
        XCTAssertEqual(expansion.missing, [])
        XCTAssertFalse(expansion.isWaiting)
        XCTAssertEqual(expansion.assignments.first?.name, "CODE_SIGN_IDENTITY", "the first include's first line comes first")
        XCTAssertEqual(expansion.assignments.last?.name, "PRODUCT_MODULE_NAME", "the file's own lines after its includes")
    }

    /// An include that is not beside the file naming it is looked for under the project's
    /// folder; a plain include found in neither is named, by the first place looked.
    func test_looksUnderTheProjectFolderAndNamesAPlainIncludeFoundNowhere() throws {
        let files: [String: String] = [
            "Config/App.xcconfig": "#include \"Shared/Base.xcconfig\"\n#include \"Nowhere.xcconfig\"\nA = app",
            "Shared/Base.xcconfig": "B = base",
        ]
        let expansion = try XcconfigExpansion(root: "Config/App.xcconfig") { path in
            files[path].map { .present(Xcconfig(parsing: $0)) } ?? .absent
        }

        XCTAssertEqual(expansion.files, ["Config/App.xcconfig", "Config/Shared/Base.xcconfig", "Shared/Base.xcconfig",
                                         "Config/Nowhere.xcconfig", "Nowhere.xcconfig"])
        XCTAssertEqual(expansion.assignments.map(\.name), ["B", "A"])
        XCTAssertEqual(expansion.missing, ["Config/Nowhere.xcconfig"])
    }

    /// A file not answered yet holds the expansion back, but not the search: every
    /// include already in reach is asked for in the same pass, and the second place for
    /// the pending one is not asked for until the first is known to be empty.
    func test_waitsOnAPendingIncludeAndStillFindsTheOthers() throws {
        let files: [String: XcconfigFile] = [
            "App.xcconfig": .present(Xcconfig(parsing: "#include \"sub/First.xcconfig\"\n#include \"Second.xcconfig\"")),
        ]
        let expansion = try XcconfigExpansion(root: "App.xcconfig") { files[$0] ?? .pending }

        XCTAssertTrue(expansion.isWaiting)
        XCTAssertEqual(expansion.files, ["App.xcconfig", "sub/First.xcconfig", "Second.xcconfig"])
    }

    func test_anIncludeCycleIsRefused() {
        let files = ["A.xcconfig": "#include \"B.xcconfig\"", "B.xcconfig": "#include \"A.xcconfig\""]

        XCTAssertThrowsError(try XcconfigExpansion(root: "A.xcconfig") { files[$0].map { .present(Xcconfig(parsing: $0)) } ?? .absent }) { error in
            XCTAssertEqual(error as? XcconfigExpansion.Failure, .includeCycle(["A.xcconfig", "B.xcconfig", "A.xcconfig"]))
        }
    }

    func test_pathsAreNormalizedAndMayClimbOutOfTheProject() {
        XCTAssertEqual(XcconfigExpansion.normalized("xcconfig/./common/../X.xcconfig"), "xcconfig/X.xcconfig")
        XCTAssertEqual(XcconfigExpansion.normalized("xcconfig/common/../../../Shared/X.xcconfig"), "../Shared/X.xcconfig")
        XCTAssertEqual(XcconfigExpansion.normalized("/Users/Shared/../X.xcconfig"), "/Users/X.xcconfig")
    }

    // MARK: - Evaluating

    /// `$(inherited)` reaches back to the assignment before it, in the same file too; a
    /// later plain assignment overrides an earlier conditional one, as Xcode reads a file
    /// top to bottom; and a `config=` condition holds for its configuration only.
    func test_eachAssignmentOverridesOrExtendsTheOnesBeforeIt() {
        let assignments = Xcconfig.assignments("""
            FLAGS = -a
            FLAGS = $(inherited) -b
            IDENTITY[sdk=macosx*] = Mac Developer
            IDENTITY = Anyone
            OPTIMIZATION = -O
            OPTIMIZATION[config=Debug] = -Onone
            """)

        let debug = XcodeBuildSettings.evaluate(assignments, in: XcodeSettingContext(sdk: "macosx", configuration: "Debug"))
        let release = XcodeBuildSettings.evaluate(assignments, in: XcodeSettingContext(sdk: "macosx", configuration: "Release"))

        XCTAssertEqual(debug["FLAGS"], "-a -b")
        XCTAssertEqual(debug["IDENTITY"], "Anyone")
        XCTAssertEqual(debug["OPTIMIZATION"], "-Onone")
        XCTAssertEqual(release["OPTIMIZATION"], "-O")
    }

    /// NetNewsWire's Mac app, Debug: every setting the bundle is made from, from files
    /// three includes deep on both the project's level and the target's.
    func test_evaluatesNetNewsWiresMacApplication() throws {
        let settings = try settings(of: "NetNewsWire")

        XCTAssertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], "com.ranchero.NetNewsWire-Evergreen-DEBUG",
                       "the organization from the target's include, the suffix from the project's")
        XCTAssertEqual(settings["PRODUCT_NAME"], "NetNewsWire")
        XCTAssertEqual(settings["PRODUCT_MODULE_NAME"], "NetNewsWire")
        XCTAssertEqual(settings["INFOPLIST_FILE"], "Mac/Resources/Info.plist")
        XCTAssertEqual(settings["CODE_SIGN_ENTITLEMENTS"], "Mac/Resources/NetNewsWire.entitlements",
                       "a setting defined empty is a reference that resolves to nothing, not one left unresolved")
        XCTAssertEqual(settings["MACOSX_DEPLOYMENT_TARGET"], "15.0")
        XCTAssertEqual(settings["SWIFT_VERSION"], "6.2")
        XCTAssertEqual(settings["SDKROOT"], "macosx")
        XCTAssertEqual(settings["MARKETING_VERSION"], "7.1.4")
        XCTAssertEqual(settings["CURRENT_PROJECT_VERSION"], "7214")
        XCTAssertEqual(settings["APP_GROUP_ID"], "group.com.ranchero.NetNewsWire-Evergreen-DEBUG")
        XCTAssertEqual(settings["CODE_SIGN_IDENTITY"], "Mac Developer")
        XCTAssertEqual(settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"], "DEBUG SKIP_APP_GROUP_ACCESS")
        XCTAssertEqual(settings["GCC_PREPROCESSOR_DEFINITIONS"], "DEBUG=1 SKIP_APP_GROUP_ACCESS=1")
        XCTAssertEqual(settings["OTHER_SWIFT_FLAGS"],
                       "-DDEBUG -DSKIP_APP_GROUP_ACCESS -Xfrontend -warn-long-function-bodies=800 -Xfrontend -warn-long-expression-type-checking=1000",
                       "the debug file assigns without $(inherited), so the project file's upcoming features are overridden — as in Xcode")
        XCTAssertEqual(settings["LD_RUNPATH_SEARCH_PATHS"], "@executable_path/../Frameworks")
        XCTAssertEqual(settings["SWIFT_OBJC_BRIDGING_HEADER"], "Mac/NetNewsWire-Bridging-Header.h")
        XCTAssertEqual(settings.unresolvedReferences, [])
    }

    func test_evaluatesNetNewsWiresReleaseConfiguration() throws {
        let settings = try settings(of: "NetNewsWire", configuration: "Release")

        XCTAssertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], "com.ranchero.NetNewsWire-Evergreen")
        XCTAssertEqual(settings["OTHER_SWIFT_FLAGS"], "-DRELEASE")
        XCTAssertNil(settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"])
    }

    /// The iOS app for the simulator: the other side of every SDK condition, and a
    /// deployment target from the project's level.
    func test_evaluatesNetNewsWiresIOSApplicationForTheSimulator() throws {
        let settings = try settings(of: "NetNewsWire-iOS", sdk: "iphonesimulator")

        XCTAssertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], "com.ranchero.NetNewsWire.iOS-DEBUG")
        XCTAssertEqual(settings["CODE_SIGN_IDENTITY"], "iPhone Developer")
        XCTAssertEqual(settings["IPHONEOS_DEPLOYMENT_TARGET"], "17.0")
        XCTAssertEqual(settings["SDKROOT"], "iphoneos")
        XCTAssertEqual(settings["TARGETED_DEVICE_FAMILY"], "1,2")
        XCTAssertEqual(settings["ASSETCATALOG_COMPILER_APPICON_NAME"], "AppIcon")
    }

    /// An extension's file names `PRODUCT_NAME = $(TARGET_NAME)` and extends the run
    /// paths its common file set.
    func test_evaluatesNetNewsWiresSafariExtension() throws {
        let settings = try settings(of: "Subscribe to Feed")

        XCTAssertEqual(settings["PRODUCT_NAME"], "Subscribe to Feed")
        XCTAssertEqual(settings["PRODUCT_MODULE_NAME"], "Subscribe_to_Feed")
        XCTAssertEqual(settings["PRODUCT_BUNDLE_IDENTIFIER"], "com.ranchero.NetNewsWire-Evergreen-DEBUG.SubscribeToFeed")
        XCTAssertEqual(settings["LD_RUNPATH_SEARCH_PATHS"], "@executable_path/../Frameworks @executable_path/../../../../Frameworks")
        XCTAssertEqual(settings["ENABLE_HARDENED_RUNTIME"], "YES")
    }

    /// A list setting is split as Xcode splits one: at whitespace, a quoted stretch one
    /// word without its quotes, a backslash keeping the character after it.
    func test_aListSettingIsSplitIntoWordsAsXcodeSplitsIt() {
        XCTAssertEqual(XcodeBuildSettings.words("-DDEBUG  -Xfrontend -warn-long-function-bodies=800 "),
                       ["-DDEBUG", "-Xfrontend", "-warn-long-function-bodies=800"])
        XCTAssertEqual(XcodeBuildSettings.words("\"NAME=two words\" 'it''s' a\\ b \"\""), ["NAME=two words", "its", "a b", ""])
        XCTAssertEqual(XcodeBuildSettings.words(""), [])
    }

    // MARK: - What the Swift compiler is told (B-77)

    private func swiftSettings(_ values: [String: String], languageMode: String? = "5") -> XcodeSwiftSettings {
        XcodeSwiftSettings(settings: XcodeBuildSettings(values: values), languageMode: languageMode)
    }

    /// Each language setting gives what Xcode 26.6's specification says it gives: a
    /// feature, its `:migrate` form, or a flag; the ones that hold only below Swift 6 give
    /// nothing in Swift 6, where the language mode has them already.
    func test_theLanguageSettingsGiveWhatXcodesSpecificationSays() {
        let values = ["SWIFT_UPCOMING_FEATURE_CONCISE_MAGIC_FILE": "YES",
                      "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "MIGRATE",
                      "SWIFT_UPCOMING_FEATURE_INTERNAL_IMPORTS_BY_DEFAULT": "YES",
                      "SWIFT_STRICT_CONCURRENCY": "complete",
                      "SWIFT_ENABLE_BARE_SLASH_REGEX": "YES",
                      "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
                      "SWIFT_STRICT_MEMORY_SAFETY": "YES",
                      "SWIFT_TREAT_WARNINGS_AS_ERRORS": "YES",
                      "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited) FEATURE",
                      "OTHER_SWIFT_FLAGS": "-Xfrontend \"-some flag\""]

        let swift5 = swiftSettings(values)
        XCTAssertEqual(swift5.upcomingFeatures, ["ConciseMagicFile", "InternalImportsByDefault", "MemberImportVisibility:migrate", "StrictConcurrency"])
        XCTAssertEqual(swift5.flags, ["-Xfrontend", "-some flag", "-enable-bare-slash-regex", "-default-isolation=MainActor",
                                      "-strict-memory-safety", "-warnings-as-errors"])
        XCTAssertEqual(swift5.defines, ["DEBUG", "$(inherited)", "FEATURE"], "the settings resolve $(inherited) before this reads them")

        let swift6 = swiftSettings(values, languageMode: "6")
        XCTAssertEqual(swift6.upcomingFeatures, ["InternalImportsByDefault", "MemberImportVisibility:migrate"])
        XCTAssertEqual(swift6.flags, ["-Xfrontend", "-some flag", "-default-isolation=MainActor", "-strict-memory-safety", "-warnings-as-errors"])
        XCTAssertEqual(swiftSettings(["SWIFT_STRICT_CONCURRENCY": "minimal"]), XcodeSwiftSettings())
    }

    /// The literals are the ones a package target's settings become: lists comma-joined,
    /// the flags a JSON list the compiler decodes, an apostrophe written so the formula's
    /// quote does not end at it.
    func test_theLiteralsAreTheOnesAPackagesSettingsBecome() throws {
        let literals = try XcodeSwiftSettings(defines: ["A", "B"], upcomingFeatures: ["ExistentialAny"],
                                              experimentalFeatures: ["DebugDescriptionMacro"],
                                              flags: ["-Xcc", "-DPATH=a/b", "-DQUOTE='x'"]).literals()

        XCTAssertEqual(literals, ["defines": "A,B", "upcomingFeatures": "ExistentialAny", "experimentalFeatures": "DebugDescriptionMacro",
                                  "unsafeFlags": "[\"-Xcc\",\"-DPATH=a/b\",\"-DQUOTE=\\u0027x\\u0027\"]"])
        let decoded = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(literals["unsafeFlags"]).utf8))
        XCTAssertEqual(decoded, ["-Xcc", "-DPATH=a/b", "-DQUOTE='x'"])
        XCTAssertEqual(try XcodeSwiftSettings().literals(), [:])
    }

    /// Xcode's defaults under every project: `DebugDescriptionMacro` on, and Approachable
    /// Concurrency off, which its five features follow.
    func test_xcodesLanguageDefaultsAreBeneathEveryLevel() throws {
        let settings = try settings(of: "NetNewsWire")

        XCTAssertEqual(settings["SWIFT_EXPERIMENTAL_FEATURE_DEBUG_DESCRIPTION_MACRO"], "YES")
        XCTAssertEqual(settings["SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES"], "NO")
        XCTAssertEqual(settings["GENERATE_PKGINFO_FILE"], "YES")
        XCTAssertEqual(try self.settings(of: "Subscribe to Feed")["GENERATE_PKGINFO_FILE"], "NO")
    }

    // MARK: - What prepare asks

    /// The files `prepare` would put in place are the ones the configurations name — the
    /// application's and its embedded extensions' — and the deployment target it writes
    /// into the config comes through three levels of includes.
    func test_theFactsOfNetNewsWiresProject() throws {
        XCTAssertEqual(try XcodeProjectFacts.xcconfigPaths(ofProjectAt: Self.netNewsWireProject), [
            "xcconfig/NetNewsWire_project_debug.xcconfig",
            "xcconfig/NetNewsWire_macapp_target.xcconfig",
            "xcconfig/NetNewsWire_shareextension_target.xcconfig",
            "xcconfig/NetNewsWire_safariextension_target.xcconfig",
            "xcconfig/NetNewsWire_iOSapp_target.xcconfig",
            "xcconfig/NetNewsWire_iOSshareextension_target.xcconfig",
            "xcconfig/NetNewsWire_iOSwidgetextension_target.xcconfig",
        ])
        XCTAssertEqual(try XcodeProjectFacts.deploymentTarget(ofProjectAt: Self.netNewsWireProject, sdk: "macosx"), "15.0")
        XCTAssertEqual(try XcodeProjectFacts.undefinedReferences(ofProjectAt: Self.netNewsWireProject, sdk: "macosx"), [])
    }

    // MARK: - Which application a platform builds (B-77)

    /// NetNewsWire has two applications, both `NetNewsWire.app`: the Mac app's
    /// `SDKROOT = macosx;` and the iOS app's `SDKROOT = iphoneos;`, each three includes
    /// deep. A Mac build is the first, a simulator build the second — the simulator builds
    /// the iOS app — and `prepare` writes that one's deployment target.
    func test_eachPlatformBuildsTheApplicationOfItsFamily() throws {
        XCTAssertEqual(try XcodeProjectFacts.applicationName(ofProjectAt: Self.netNewsWireProject, sdk: "macosx"), "NetNewsWire")
        XCTAssertEqual(try XcodeProjectFacts.applicationName(ofProjectAt: Self.netNewsWireProject, sdk: "iphonesimulator"), "NetNewsWire-iOS")
        XCTAssertEqual(try XcodeProjectFacts.applicationName(ofProjectAt: Self.netNewsWireProject, sdk: "iphoneos"), "NetNewsWire-iOS")
        XCTAssertEqual(try XcodeProjectFacts.deploymentTarget(ofProjectAt: Self.netNewsWireProject, sdk: "iphonesimulator"), "17.0")
        XCTAssertEqual(try XcodeProjectFacts.undefinedReferences(ofProjectAt: Self.netNewsWireProject, sdk: "iphonesimulator"), [])
        XCTAssertEqual(try XcodeProjectFacts.applicationName(ofProjectAt: Self.netNewsWireProject, sdk: "iphonesimulator",
                                                             named: "NetNewsWire"), "NetNewsWire", "a name picks one whatever the platform")
    }

    /// Two applications for one platform are an error naming both, which a name settles;
    /// none for the platform is an error naming each with what it builds for; one stating
    /// no platform is taken when none states this one.
    func test_twoApplicationsForOnePlatformAreAnErrorUntilANamePicksOne() throws {
        let project = try XcodeProject(pbxproj: try Data(contentsOf: Self.netNewsWireProject.appendingPathComponent("project.pbxproj")))
        func settings(_ values: [String: [String: String]]) -> (XcodeProject.Target) throws -> XcodeBuildSettings {
            { target in XcodeBuildSettings(values: values[target.name] ?? [:]) }
        }
        let bothIOS = settings(["NetNewsWire": ["SDKROOT": "iphoneos"], "NetNewsWire-iOS": ["SDKROOT": "iphoneos"]])

        XCTAssertThrowsError(try project.application(forSDK: "iphonesimulator", named: nil, settings: bothIOS)) { error in
            XCTAssertEqual("\(error)", "2 application targets build for iphonesimulator: NetNewsWire, NetNewsWire-iOS; "
                                     + "name the one to build with application: '<name>' on XcodeProjectConverter, or --application <name> to prepare")
        }
        XCTAssertEqual(try project.application(forSDK: "iphonesimulator", named: "NetNewsWire-iOS", settings: bothIOS).name, "NetNewsWire-iOS")
        XCTAssertThrowsError(try project.application(forSDK: "iphonesimulator", named: "Nope", settings: bothIOS)) { error in
            XCTAssertEqual("\(error)", "the project has no application target named 'Nope'; it has NetNewsWire, NetNewsWire-iOS")
        }
        XCTAssertThrowsError(try project.application(forSDK: "xrsimulator", named: nil, settings: bothIOS)) { error in
            XCTAssertEqual("\(error)", "no application target builds for xrsimulator: the project has NetNewsWire (iphoneos), NetNewsWire-iOS (iphoneos)")
        }

        let multiplatform = settings(["NetNewsWire": ["SDKROOT": "auto", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx"],
                                      "NetNewsWire-iOS": ["SDKROOT": "macosx"]])
        XCTAssertThrowsError(try project.application(forSDK: "macosx", named: nil, settings: multiplatform))
        XCTAssertEqual(try project.application(forSDK: "iphonesimulator", named: nil, settings: multiplatform).name, "NetNewsWire")

        let unstated = settings(["NetNewsWire-iOS": ["SDKROOT": "macosx"]])
        XCTAssertEqual(try project.application(forSDK: "iphonesimulator", named: nil, settings: unstated).name, "NetNewsWire")
        XCTAssertEqual(try project.application(forSDK: "macosx", named: nil, settings: unstated).name, "NetNewsWire-iOS",
                       "one stating the platform wins over one stating none")
    }

    func test_aSimulatorSDKIsOfItsDeviceSDKsFamily() {
        XCTAssertEqual(XcodeProject.platformFamily(ofSDK: "iphonesimulator"), "iphoneos")
        XCTAssertEqual(XcodeProject.platformFamily(ofSDK: "iphonesimulator26.5"), "iphoneos")
        XCTAssertEqual(XcodeProject.platformFamily(ofSDK: "/SDKs/iPhoneSimulator26.5.sdk"), "iphoneos")
        XCTAssertEqual(XcodeProject.platformFamily(ofSDK: "iphoneos"), "iphoneos")
        XCTAssertEqual(XcodeProject.platformFamily(ofSDK: "macosx"), "macosx")
        XCTAssertEqual(XcodeProject.platformFamily(ofSDK: "xrsimulator"), "xros")
        XCTAssertEqual(XcodeProject.platformFamily(ofSDK: "watchsimulator"), "watchos")
    }
}
