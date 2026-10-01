//
//  CodeEditFixtureTests.swift
//  SemelAppleTests
//
//  What Semel makes of CodeEdit's own files (B-77 item 3): `Fixtures/CodeEdit` holds its
//  project file, the five `Configs` xcconfigs every configuration is based on, and the app's
//  and the Finder extension's `Info.plist` and entitlements, as they are at
//  fa2aebd86373211c78626074b53ab75010767575, under its MIT licence. The plists are built
//  the way a build builds them — the settings evaluated from the project, the keys and
//  settings the emitter hands the builder, the project's file as the base — and compared
//  with what Xcode 26.6 put in the bundles it built from the same commit.
//

@testable import SemelApple
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class CodeEditFixtureTests: SemelAppleTestCase {

    /// CodeEdit's project folder, as far as the fixture copies it.
    static var codeEdit: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/CodeEdit", isDirectory: true)
    }

    private func project() throws -> XcodeProject {
        try XcodeProject(pbxproj: try Data(contentsOf: Self.codeEdit.appendingPathComponent("CodeEdit.xcodeproj/project.pbxproj")))
    }

    /// One target's settings for the Mac, its xcconfig read from the fixture as `prepare`
    /// reads it from a clone.
    private func target(named targetName: String) throws -> (target: XcodeProject.Target, settings: XcodeBuildSettings) {
        let project = try project()
        let target = try XCTUnwrap(project.targets.first { $0.name == targetName })
        let expansions = try XcodeProjectFacts.expansions(of: project.xcconfigPaths(for: target, configuration: "Debug"),
                                                          in: Self.codeEdit)
        let settings = try XcodeBuildSettings.resolve(project: project, target: target, configuration: "Debug", sdk: "macosx",
                                                      xcconfig: { expansions[$0]?.assignments },
                                                      extra: ["TARGET_NAME": target.name])
        return (target, settings)
    }

    /// The target's Info.plist as its `InfoPlistBuilder` builds it, with no partials.
    private func builtInfoPlist(of targetName: String) throws -> [String: Any] {
        let (target, settings) = try target(named: targetName)
        let identity   = try TargetIdentity(target: target, settings: settings, sdk: "macosx")
        let properties = try XcodeFormulaEmitter.infoPlistProperties(identity: identity, settings: settings, targetName: target.name)
        let fileName   = try XCTUnwrap(settings["INFOPLIST_FILE"])
        let base       = try [UInt8](Data(contentsOf: Self.codeEdit.appendingPathComponent(fileName))).intern()

        let node = try InfoPlistBuilder(thisNode: NodeRecord(id: 1, kind: InfoPlistBuilder.kind, name: nil,
                                                             properties: properties, scheduled: false, identity: nil))
        let output = try node.process(input: ProcessInput(inputValues: [InfoPlistBuilder.base: [fileName: .value(base)]]))
        let hash  = try XCTUnwrap(output.outputValues[InfoPlistBuilder.output]).expectValue()
        let bytes = try XCTUnwrap(try DataObjectStore.shared.read(hash: hash))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String: Any])
    }

    // MARK: - Info.plist

    /// `GENERATE_INFOPLIST_FILE = NO`: the app's plist is its file, which states
    /// `CFBundleShortVersionString = 0.3.6` while `MARKETING_VERSION` is "Change in
    /// Info.plist". Xcode's app says 0.3.6; the identity and version are the file's, the
    /// platform's keys are added, and `INFOPLIST_KEY_NSPrincipalClass` names a class the
    /// app does not have and stays out.
    func test_theAppsPlistIsItsFileWithThePlatformsKeys() throws {
        let plist = try builtInfoPlist(of: "CodeEdit")

        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "0.3.6")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "47")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "app.codeedit.CodeEdit")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "CodeEdit")
        XCTAssertEqual(plist["CFBundleName"] as? String, "CodeEdit")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "en")
        XCTAssertEqual(plist["CE_VERSION_POSTFIX"] as? String, "-dev")
        XCTAssertEqual(plist["NSHumanReadableCopyright"] as? String, "Copyright © 2022-2025 CodeEdit")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(plist["CFBundleSupportedPlatforms"] as? [String], ["MacOSX"])
        XCTAssertEqual(plist["DTPlatformName"] as? String, "macosx")
        XCTAssertNil(plist["NSPrincipalClass"])
    }

    /// The Finder extension's file says 0.3.6 too, and its `MARKETING_VERSION` is 1.0;
    /// Xcode's extension says 0.3.6, as its app does.
    func test_theExtensionsPlistIsItsFileWithThePlatformsKeys() throws {
        let plist = try builtInfoPlist(of: "OpenWithCodeEdit")

        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "0.3.6")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "47")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "app.codeedit.CodeEdit.OpenWithCodeEdit")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "OpenWithCodeEdit")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "XPC!")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
        let principalClass = (plist["NSExtension"] as? [String: Any])?["NSExtensionPrincipalClass"] as? String
        XCTAssertEqual(principalClass, "OpenWithCodeEdit.CEOpenWith")
    }
}
