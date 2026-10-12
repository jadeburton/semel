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

    /// lex reports flex's release and Apple's build of it, both kept.
    func test_parseLexVersion_keepsApplesBuild() {
        XCTAssertEqual(ClangToolDiscovery.parseLexVersion(from: "flex 2.6.4 Apple(flex-35)\n"), "flex 2.6.4 Apple(flex-35)")
        XCTAssertEqual(ClangToolDiscovery.parseLexVersion(from: "flex 2.5.35"), "flex 2.5.35")
        XCTAssertNil(ClangToolDiscovery.parseLexVersion(from: "Apple clang version 21.0.0"))
    }

    // MARK: - Declaration

    func test_registeringTheToolchainDeclaresClangLibtoolAndLex() {
        XCTAssertTrue(ToolDiscovery.all.contains { $0.name == "clang" })
        XCTAssertTrue(ToolDiscovery.all.contains { $0.name == "libtool" })
        XCTAssertTrue(ToolDiscovery.all.contains { $0.name == "lex" })
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

    func test_lexIsLocatedAndReportsItsVersion() throws {
        let path = try XCTUnwrap(ClangToolDiscovery.locate("lex"), "lex must be discoverable via xcrun")
        let version = try XCTUnwrap(ClangToolDiscovery.lexVersion(ofToolAt: path))
        XCTAssertTrue(version.hasPrefix("flex "), "got \(version)")
    }

    /// B-157. The toolchain's `lex` is a script that runs `flex`, and flex expands its
    /// skeleton through `m4`, a wrapper that runs `gm4` or `bm4`: two toolchains whose
    /// script is the same bytes and whose m4 is not are told apart by lex's fingerprint.
    func test_lexIsFingerprintedWithTheFlexAndM4ItRuns() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-lex-helpers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func toolchain(_ name: String, gm4: String) throws -> String {
            let bin = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for (file, bytes) in [("lex", "exec flex"), ("flex", "the same flex"), ("m4", "the same wrapper"), ("gm4", gm4)] {
                try Data(bytes.utf8).write(to: bin.appendingPathComponent(file))
            }
            return bin.appendingPathComponent("lex").path
        }
        let first  = try toolchain("first", gm4: "one m4")
        let second = try toolchain("second", gm4: "another m4")

        let fingerprint = try XCTUnwrap(ClangToolDiscovery.lexFinder.companionFingerprint(first))
        XCTAssertEqual(fingerprint.split(separator: "\n").map { $0.prefix { $0 != "=" } }, ["flex", "gm4", "m4"])
        XCTAssertNotEqual(fingerprint, ClangToolDiscovery.lexFinder.companionFingerprint(second))
    }

    func test_aToolThatDoesNotExistIsNotLocated() {
        XCTAssertNil(ClangToolDiscovery.locate("definitely-not-a-real-tool-name"))
    }
}
