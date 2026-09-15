//
//  ClangToolDiscoveryTests.swift
//  SemelClangTests
//

@testable import SemelClang
import Foundation
import SemelNodeKit
import XCTest

/// What this package declares it can find, and how it reads the version — the string
/// that keys the cache, so its exact shape matters.
final class ClangToolDiscoveryTests: SemelClangTestCase {

    // MARK: - Version parsing

    // The build identifier is part of the compiler's identity — two clangs with the same
    // marketing version and different build ids are different binaries — so it stays in
    // the string that keys the cache.
    func test_parseVersion_keepsTheBuildIdentifier() {
        let output = "Apple clang version 21.0.0 (clang-2100.1.1.101)\nTarget: arm64-apple-darwin25.3.0"
        XCTAssertEqual(ClangToolDiscovery.parseVersion(from: output),
                       "Apple clang version 21.0.0 (clang-2100.1.1.101)")
    }

    func test_parseVersion_withoutABuildIdentifier() {
        XCTAssertEqual(ClangToolDiscovery.parseVersion(from: "Apple clang version 21.0.0"),
                       "Apple clang version 21.0.0")
    }

    func test_parseVersion_unrecognisedOutput() {
        XCTAssertNil(ClangToolDiscovery.parseVersion(from: "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3)"),
                     "another tool's version is not this tool's")
        XCTAssertNil(ClangToolDiscovery.parseVersion(from: "some tool that reports nothing useful"))
    }

    // MARK: - Declaration

    func test_registeringTheToolchainDeclaresClang() {
        XCTAssertTrue(ToolDiscovery.all.contains { $0.name == "clang" })
    }

    // MARK: - This machine

    func test_clangIsLocatedAndReportsItsVersion() throws {
        let path = try XCTUnwrap(ClangToolDiscovery.locate("clang"), "clang must be discoverable via xcrun")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), "\(path) must be an executable")

        let version = try XCTUnwrap(ClangToolDiscovery.version(ofToolAt: path))
        XCTAssertTrue(version.hasPrefix("Apple clang version"), "got \(version)")
    }

    func test_aToolThatDoesNotExistIsNotLocated() {
        XCTAssertNil(ClangToolDiscovery.locate("definitely-not-a-real-tool-name"))
    }
}
