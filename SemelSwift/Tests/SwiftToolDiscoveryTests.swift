//
//  SwiftToolDiscoveryTests.swift
//  SemelSwiftTests
//

@testable import SemelSwift
import Foundation
import SemelNodeKit
import XCTest

/// What this package declares it can find, and how it reads the version — the string
/// that keys the cache, so its exact shape matters.
final class SwiftToolDiscoveryTests: SemelSwiftTestCase {

    // MARK: - Version parsing

    // swiftc leads with its driver version, which is noise; the tool's own version is
    // mid-line and carries the swiftlang build id, which stays: two compilers sharing a
    // marketing version with different build ids are different binaries.
    func test_parseVersion_skipsTheDriverVersionAndKeepsTheBuildIdentifier() {
        let output = "swift-driver version: 1.148.6 Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)"
        XCTAssertEqual(SwiftToolDiscovery.parseVersion(from: output),
                       "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)")
    }

    func test_parseVersion_withoutABuildIdentifier() {
        XCTAssertEqual(SwiftToolDiscovery.parseVersion(from: "Apple Swift version 6.2.3"),
                       "Apple Swift version 6.2.3")
    }

    func test_parseVersion_unrecognisedOutput() {
        XCTAssertNil(SwiftToolDiscovery.parseVersion(from: "Apple clang version 21.0.0 (clang-2100.1.1.101)"),
                     "another tool's version is not this tool's")
        XCTAssertNil(SwiftToolDiscovery.parseVersion(from: "some tool that reports nothing useful"))
    }

    // MARK: - Declaration

    func test_registeringTheToolchainDeclaresTheCompilerAndThePackageTool() {
        let declared = Set(ToolDiscovery.all.map(\.name))
        XCTAssertTrue(declared.isSuperset(of: ["swiftc", "swift"]), "\(declared)")
    }

    // MARK: - This machine

    func test_theCompilerIsLocatedAndReportsItsVersion() throws {
        let path = try XCTUnwrap(SwiftToolDiscovery.locate("swiftc"), "swiftc must be discoverable via xcrun")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), "\(path) must be an executable")

        let version = try XCTUnwrap(SwiftToolDiscovery.version(ofToolAt: path))
        XCTAssertTrue(version.hasPrefix("Apple Swift version"), "got \(version)")
    }

    func test_aToolThatDoesNotExistIsNotLocated() {
        XCTAssertNil(SwiftToolDiscovery.locate("definitely-not-a-real-tool-name"))
    }
}
