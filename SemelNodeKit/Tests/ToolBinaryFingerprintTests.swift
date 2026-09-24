//
//  ToolBinaryFingerprintTests.swift
//  SemelNodeKitTests
//
//  B-17. A tool descriptor names a version, and a version is what a binary says about
//  itself: two binaries say the same thing, and only a fingerprint of the binary tells
//  them apart. These pin what the fingerprint covers, and that it stays out of the way of
//  the one thing a config file does decide — which tool a node runs.
//

@testable import SemelNodeKit
import Foundation
import XCTest

final class ToolBinaryFingerprintTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-tool-fingerprint-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeBinary(named name: String, contents: String, modified: Date) throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - What the fingerprint covers

    func test_oneBinaryFingerprintsTheSameEveryTimeItIsAsked() throws {
        let path = try writeBinary(named: "tool", contents: "binary", modified: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(toolBinaryFingerprint(ofFileAt: path), toolBinaryFingerprint(ofFileAt: path))
    }

    /// The common shape of the problem: a toolchain reinstalled over itself, reporting the
    /// version it always did.
    func test_aBinaryReplacedInPlaceFingerprintsDifferently() throws {
        let path = try writeBinary(named: "tool", contents: "binary", modified: Date(timeIntervalSince1970: 1_000))
        let before = toolBinaryFingerprint(ofFileAt: path)

        try writeBinary(named: "tool", contents: "a patched binary", modified: Date(timeIntervalSince1970: 2_000))

        XCTAssertNotEqual(before, toolBinaryFingerprint(ofFileAt: path))
    }

    /// Same size, same path: the modification time is what is left to notice a rebuild by.
    func test_aRebuiltBinaryOfTheSameSizeFingerprintsDifferently() throws {
        let path = try writeBinary(named: "tool", contents: "binary", modified: Date(timeIntervalSince1970: 1_000))
        let before = toolBinaryFingerprint(ofFileAt: path)

        try writeBinary(named: "tool", contents: "binexe", modified: Date(timeIntervalSince1970: 3_000))

        XCTAssertNotEqual(before, toolBinaryFingerprint(ofFileAt: path))
    }

    /// `swiftc` in an Apple toolchain is a symlink to `swift-frontend`, which is the binary
    /// that does the work: the link is followed, so the fingerprint describes the frontend.
    func test_aSymlinkFingerprintsAsWhatItPointsAt() throws {
        let target = try writeBinary(named: "swift-frontend", contents: "frontend",
                                     modified: Date(timeIntervalSince1970: 1_000))
        let link = folder.appendingPathComponent("swiftc")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "swift-frontend")

        XCTAssertEqual(toolBinaryFingerprint(ofFileAt: link.path), toolBinaryFingerprint(ofFileAt: target))
    }

    /// The path is part of the answer, so two toolchains holding identical files — one
    /// Xcode beside another — are still two different binaries.
    func test_identicalBinariesAtTwoPathsFingerprintDifferently() throws {
        let modified = Date(timeIntervalSince1970: 1_000)
        let one      = try writeBinary(named: "toolA", contents: "binary", modified: modified)
        let another  = try writeBinary(named: "toolB", contents: "binary", modified: modified)

        XCTAssertNotEqual(toolBinaryFingerprint(ofFileAt: one), toolBinaryFingerprint(ofFileAt: another))
    }

    func test_thereIsNoFingerprintOfWhatIsNotAFile() throws {
        XCTAssertNil(toolBinaryFingerprint(ofFileAt: folder.appendingPathComponent("absent").path))
        XCTAssertNil(toolBinaryFingerprint(ofFileAt: folder.path), "a folder is not a binary")
    }

    // MARK: - What selects a tool

    private struct NoTool: ToolRunner {
        func execute(arguments: [String],
                     environment: [String: String],
                     inputFiles: [FileNameAndContent],
                     expectedOutputFileNames: [String],
                     expectedOutputFolders: [String],
                     output: ToolOutput) throws -> ToolExecuteResult {
            ToolExecuteResult(exitCode: 0, resolvedSandboxPath: "/tmp/no-tool")
        }
    }

    private func descriptor(recursiveHash: String?) -> ToolDescriptor {
        .init(name: "faketool", version: "1.0", platform: "macOS", architecture: "arm64",
              recursiveHash: recursiveHash)
    }

    /// A config file — hand-written, or written by `semel-swift prepare` — names four
    /// fields and no fingerprint. It has to go on selecting the tool it always selected.
    func test_aConfigurationWithoutAFingerprintSelectsTheInstalledTool() throws {
        let registry = ToolRunnerRegistry()
        registry.registerTool(descriptor: descriptor(recursiveHash: "fingerprint"), toolExecutor: NoTool())

        XCTAssertNoThrow(try registry.tool(descriptor: descriptor(recursiveHash: nil)))
    }

    /// And a stale fingerprint in a config file does not un-select it either: the four
    /// identity fields are the whole question.
    func test_aStaleFingerprintInAConfigurationSelectsTheInstalledToolToo() throws {
        let registry = ToolRunnerRegistry()
        registry.registerTool(descriptor: descriptor(recursiveHash: "fingerprint"), toolExecutor: NoTool())

        XCTAssertNoThrow(try registry.tool(descriptor: descriptor(recursiveHash: "a fingerprint of something else")))
    }

    /// What a node's cache key reads: the identity it asked for, answered with the whole
    /// registered descriptor, fingerprint included.
    func test_theRegisteredDescriptorCarriesTheFingerprintTheIdentityDoesNot() throws {
        let registry = ToolRunnerRegistry()
        registry.registerTool(descriptor: descriptor(recursiveHash: "fingerprint"), toolExecutor: NoTool())

        let identity = try XCTUnwrap(ToolDescriptor.Identity(properties: [
            "toolDescriptor.name":         "faketool",
            "toolDescriptor.version":      "1.0",
            "toolDescriptor.platform":     "macOS",
            "toolDescriptor.architecture": "arm64",
        ]))

        XCTAssertEqual(registry.registeredDescriptor(matching: identity)?.recursiveHash, "fingerprint")
        XCTAssertNil(registry.registeredDescriptor(matching: .init(name: "faketool", version: "2.0",
                                                                   platform: "macOS", architecture: "arm64")))
    }

    func test_aConfigurationMissingAnIdentityFieldNamesNoTool() {
        XCTAssertNil(ToolDescriptor.Identity(properties: ["toolDescriptor.name": "faketool"]))
        XCTAssertNil(ToolDescriptor.Identity(properties: [:]))
    }
}
