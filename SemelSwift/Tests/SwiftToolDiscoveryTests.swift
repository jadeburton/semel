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

    // MARK: - The compiler's plugins (B-80)

    /// A toolchain's `usr` and a platforms folder, under a fresh folder, holding the plugin
    /// files the compiler runs; `observation` is the bytes of the toolchain's Observation
    /// plugin, which a test changes.
    private func pluginTrees(observation: String = "observation") throws -> (toolchain: URL, platforms: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-swift-plugins-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = [
            "toolchain/usr/bin/swift-frontend":                                              "frontend",
            "toolchain/usr/lib/swift/host/plugins/libObservationMacros.dylib":               observation,
            "toolchain/usr/lib/swift/host/libSwiftSyntax.dylib":                             "syntax",
            "Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftDataMacros.dylib": "swiftdata",
            "Platforms/MacOSX.platform/Developer/usr/bin/swift-plugin-server":               "server",
            "Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/SDKSettings.json":          "{}",
        ]
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        return (root.appendingPathComponent("toolchain/usr"), root.appendingPathComponent("Platforms"))
    }

    /// Where the toolchain sits is not the fingerprint: two copies of one toolchain agree,
    /// as two copies of one binary do.
    func test_thePluginFingerprintDoesNotDependOnWhereTheToolchainIs() throws {
        let first = try pluginTrees(), second = try pluginTrees()

        let fingerprint = try XCTUnwrap(SwiftCompilerPlugins.fingerprint(toolchain: first.toolchain, platforms: first.platforms))
        XCTAssertEqual(SwiftCompilerPlugins.fingerprint(toolchain: second.toolchain, platforms: second.platforms), fingerprint)
    }

    /// A plugin's bytes are the fingerprint, the toolchain's and the platform's alike: a
    /// toolchain whose Observation plugin differs keys apart from one whose does not, as
    /// does a platform without its SwiftData plugin.
    func test_thePluginFingerprintFollowsThePluginsBytes() throws {
        let original = try pluginTrees()
        let patched  = try pluginTrees(observation: "observation, patched")
        let fingerprint = SwiftCompilerPlugins.fingerprint(toolchain: original.toolchain, platforms: original.platforms)

        XCTAssertNotEqual(SwiftCompilerPlugins.fingerprint(toolchain: patched.toolchain, platforms: patched.platforms), fingerprint)
        XCTAssertNotEqual(SwiftCompilerPlugins.fingerprint(toolchain: original.toolchain, platforms: nil), fingerprint,
                          "the platform's plugins are part of it")
    }

    /// The SDK beside the platform's plugins is not: it is the SDK fingerprint's.
    func test_thePluginFingerprintLeavesTheSDKOut() throws {
        let trees = try pluginTrees()
        let fingerprint = SwiftCompilerPlugins.fingerprint(toolchain: trees.toolchain, platforms: trees.platforms)

        try Data("{\"changed\": true}".utf8).write(to: trees.platforms.appendingPathComponent("MacOSX.platform/Developer/SDKs/MacOSX.sdk/Other.json"))
        XCTAssertEqual(SwiftCompilerPlugins.fingerprint(toolchain: trees.toolchain, platforms: trees.platforms), fingerprint)
    }

    /// A compiler with no plugins anywhere has nothing to fold into its fingerprint.
    func test_aToolchainWithoutPluginsHasNoPluginFingerprint() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-swift-no-plugins-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNil(SwiftCompilerPlugins.fingerprint(toolchain: empty, platforms: nil))
    }

    /// This machine's compiler has its toolchain's plugins, and the descriptor discovery
    /// registers for it is not its binary's fingerprint alone.
    func test_thisMachinesCompilerFingerprintsItsPlugins() throws {
        let path = try XCTUnwrap(SwiftToolDiscovery.locate("swiftc"))
        let plugins = try XCTUnwrap(SwiftCompilerPlugins.fingerprint(ofToolAt: path))
        let binary  = try XCTUnwrap(toolBinaryFingerprint(ofFileAt: path))

        XCTAssertNotEqual(toolFingerprint(binary: binary, companions: plugins), binary)
    }
}
