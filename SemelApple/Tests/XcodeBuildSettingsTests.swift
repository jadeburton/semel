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
        ])
        XCTAssertEqual(try XcodeProjectFacts.deploymentTarget(ofProjectAt: Self.netNewsWireProject, sdk: "macosx"), "15.0")
        XCTAssertEqual(try XcodeProjectFacts.undefinedReferences(ofProjectAt: Self.netNewsWireProject, sdk: "macosx"), [])
    }
}
