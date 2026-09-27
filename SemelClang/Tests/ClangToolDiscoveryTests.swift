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

    /// libtool reports one line, and the cctools release on it is what tells two apart.
    func test_parseLibtoolVersion_keepsTheCctoolsRelease() {
        XCTAssertEqual(ClangToolDiscovery.parseLibtoolVersion(from: "Apple Inc. version cctools_ld-1267\n"),
                       "Apple Inc. version cctools_ld-1267")
        XCTAssertEqual(ClangToolDiscovery.parseLibtoolVersion(from: "Apple Inc. version cctools-1024.3"),
                       "Apple Inc. version cctools-1024.3")
    }

    func test_parseLibtoolVersion_unrecognisedOutput() {
        XCTAssertNil(ClangToolDiscovery.parseLibtoolVersion(from: "Apple clang version 21.0.0"),
                     "another tool's version is not this tool's")
        XCTAssertNil(ClangToolDiscovery.parseLibtoolVersion(from: ""))
    }

    // MARK: - Declaration

    func test_registeringTheToolchainDeclaresClangAndLibtool() {
        XCTAssertTrue(ToolDiscovery.all.contains { $0.name == "clang" })
        XCTAssertTrue(ToolDiscovery.all.contains { $0.name == "libtool" })
    }

    // MARK: - This machine

    func test_clangIsLocatedAndReportsItsVersion() throws {
        let path = try XCTUnwrap(ClangToolDiscovery.locate("clang"), "clang must be discoverable via xcrun")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), "\(path) must be an executable")

        let version = try XCTUnwrap(ClangToolDiscovery.version(ofToolAt: path))
        XCTAssertTrue(version.hasPrefix("Apple clang version"), "got \(version)")
    }

    func test_libtoolIsLocatedAndReportsItsVersion() throws {
        let path = try XCTUnwrap(ClangToolDiscovery.locate("libtool"), "libtool must be discoverable via xcrun")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), "\(path) must be an executable")

        let version = try XCTUnwrap(ClangToolDiscovery.libtoolVersion(ofToolAt: path))
        XCTAssertTrue(version.hasPrefix("Apple Inc. version"), "got \(version)")
    }

    func test_aToolThatDoesNotExistIsNotLocated() {
        XCTAssertNil(ClangToolDiscovery.locate("definitely-not-a-real-tool-name"))
    }
}
