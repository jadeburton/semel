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
        XCTAssertTrue(declared.isSuperset(of: ["actool", "xcstringstool"]), "\(declared)")
    }

    // MARK: - This machine

    func test_theResourceToolsAreLocatedUnderVersionsThatNameABuild() throws {
        let actool = try XCTUnwrap(AppleToolDiscovery.locate("actool"), "actool must be discoverable via xcrun")
        let actoolVersion = try XCTUnwrap(AppleToolDiscovery.actoolVersion(at: actool))
        XCTAssertTrue(actoolVersion.hasPrefix("Apple actool version ") && actoolVersion.contains("("), actoolVersion)

        XCTAssertNotNil(AppleToolDiscovery.locate("xcstringstool"), "xcstringstool must be discoverable via xcrun")
        let xcode = try XCTUnwrap(AppleToolDiscovery.xcodeVersion())
        XCTAssertTrue(xcode.hasPrefix("Xcode ") && xcode.contains("("), xcode)
    }
}
