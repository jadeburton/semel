//
//  AppleToolDiscoveryTests.swift
//  SemelAppleTests
//

@testable import SemelApple
import Foundation
import SemelNodeKit
import XCTest

/// The resource tools report their versions differently from the compilers: actool
/// answers `--version` with a plist, and xcstringstool has no version of its own, so it is
/// identified by the Xcode that ships it. Both must end up with a version that names a
/// build, since the descriptor keys the cache.
final class AppleToolDiscoveryTests: SemelAppleTestCase {

    // MARK: - actool

    private let actoolPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.actool.version</key>
            <dict>
                <key>bundle-version</key>
                <string>26010</string>
                <key>short-bundle-version</key>
                <string>26.0</string>
            </dict>
        </dict>
        </plist>
        """

    func test_actoolVersion_isReadFromThePlistMarketingVersionThenBuild() {
        XCTAssertEqual(AppleToolDiscovery.actoolVersion(fromPlist: actoolPlist), "Apple actool version 26.0 (26010)")
    }

    func test_actoolVersion_unrecognisedOutput() {
        XCTAssertNil(AppleToolDiscovery.actoolVersion(fromPlist: "actool 26.0"))
        XCTAssertNil(AppleToolDiscovery.actoolVersion(fromPlist: "<plist version=\"1.0\"><dict/></plist>"))
    }

    // MARK: - ibtool

    /// ibtool answers as actool does, under its own key.
    func test_ibtoolVersion_isReadFromThePlistUnderItsOwnKey() {
        let ibtoolPlist = actoolPlist.replacingOccurrences(of: "com.apple.actool.version", with: "com.apple.ibtool.version")
        XCTAssertEqual(AppleToolDiscovery.ibtoolVersion(fromPlist: ibtoolPlist), "Apple ibtool version 26.0 (26010)")
        XCTAssertNil(AppleToolDiscovery.ibtoolVersion(fromPlist: actoolPlist), "actool's version is not ibtool's")
    }

    // MARK: - Xcode

    func test_xcodeVersion_isTheVersionLineWithTheBuild() {
        XCTAssertEqual(AppleToolDiscovery.xcodeVersion(from: "Xcode 26.6\nBuild version 17F113"),
                       "Xcode 26.6 (17F113)")
    }

    func test_xcodeVersion_withoutABuildLine() {
        XCTAssertEqual(AppleToolDiscovery.xcodeVersion(from: "Xcode 26.6"), "Xcode 26.6")
    }

    func test_xcodeVersion_unrecognisedOutput() {
        XCTAssertNil(AppleToolDiscovery.xcodeVersion(from: "xcodebuild: error: no developer directory"))
    }

    // MARK: - Declaration

    func test_registeringTheToolchainDeclaresTheResourceTools() {
        let declared = Set(ToolDiscovery.all.map(\.name))
        XCTAssertTrue(declared.isSuperset(of: ["actool", "ibtool", "xcstringstool"]), "\(declared)")
    }

    /// ibtool's namespace declares the SDK as a machine setting, which prepare writes: its
    /// path, and the fingerprint of the tree behind it (B-47).
    func test_ibtoolsNamespaceDeclaresTheSDKAsAMachineSetting() throws {
        let namespace = try XCTUnwrap(ToolNamespaceRegistry.entry(forNamespace: "apple.ibToolCompiler"))
        XCTAssertEqual(namespace.toolName, "ibtool")
        XCTAssertEqual(namespace.machineSettingKeys, ["sdkPath", "sdkFingerprint"])
        XCTAssertEqual(namespace.machineFileWriter?.command, "semel-swift prepare")
    }

    // MARK: - This machine

    func test_theResourceToolsAreLocatedUnderVersionsThatNameABuild() throws {
        let actool = try XCTUnwrap(AppleToolDiscovery.locate("actool"), "actool must be discoverable via xcrun")
        let actoolVersion = try XCTUnwrap(AppleToolDiscovery.actoolVersion(at: actool))
        XCTAssertTrue(actoolVersion.hasPrefix("Apple actool version ") && actoolVersion.contains("("), actoolVersion)

        let ibtool = try XCTUnwrap(AppleToolDiscovery.locate("ibtool"), "ibtool must be discoverable via xcrun")
        let ibtoolVersion = try XCTUnwrap(AppleToolDiscovery.ibtoolVersion(at: ibtool))
        XCTAssertTrue(ibtoolVersion.hasPrefix("Apple ibtool version ") && ibtoolVersion.contains("("), ibtoolVersion)

        XCTAssertNotNil(AppleToolDiscovery.locate("xcstringstool"), "xcstringstool must be discoverable via xcrun")
        let xcode = try XCTUnwrap(AppleToolDiscovery.xcodeVersion())
        XCTAssertTrue(xcode.hasPrefix("Xcode ") && xcode.contains("("), xcode)
    }
}
