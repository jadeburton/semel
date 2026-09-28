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

        XCTAssertEqual(toolBinaryContentFingerprint(ofFileAt: path),
                       toolBinaryContentFingerprint(ofFileAt: path))
    }

    /// The common shape of the problem: a toolchain reinstalled over itself, reporting the
    /// version it always did.
    func test_aBinaryReplacedInPlaceFingerprintsDifferently() throws {
        let path = try writeBinary(named: "tool", contents: "binary", modified: Date(timeIntervalSince1970: 1_000))
        let before = toolBinaryContentFingerprint(ofFileAt: path)

        try writeBinary(named: "tool", contents: "a patched binary", modified: Date(timeIntervalSince1970: 2_000))

        XCTAssertNotEqual(before, toolBinaryContentFingerprint(ofFileAt: path))
    }

    /// The case size and modification time cannot see: a patched binary of the same length
    /// restored over the original with its timestamp preserved. Only the bytes say so.
    func test_aBinaryOfTheSameSizeAndTimeFingerprintsByItsBytes() throws {
        let sameTime = Date(timeIntervalSince1970: 1_000)
        let path = try writeBinary(named: "tool", contents: "binary", modified: sameTime)
        let before = toolBinaryContentFingerprint(ofFileAt: path)

        try writeBinary(named: "tool", contents: "binexe", modified: sameTime)

        XCTAssertNotEqual(before, toolBinaryContentFingerprint(ofFileAt: path))
    }

    /// `swiftc` in an Apple toolchain is a symlink to `swift-frontend`, which is the binary
    /// that does the work: the link is followed, so the fingerprint describes the frontend.
    func test_aSymlinkFingerprintsAsWhatItPointsAt() throws {
        let target = try writeBinary(named: "swift-frontend", contents: "frontend",
                                     modified: Date(timeIntervalSince1970: 1_000))
        let link = folder.appendingPathComponent("swiftc")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "swift-frontend")

        XCTAssertEqual(toolBinaryContentFingerprint(ofFileAt: link.path),
                       toolBinaryContentFingerprint(ofFileAt: target))
    }

    /// Nothing but the bytes: one toolchain installed at two places — `/Applications/Xcode.app`
    /// on one machine and `/Applications/Xcode_26_6.app` on another — fingerprints alike, which
    /// is what lets two machines share a cache entry.
    func test_identicalBinariesAtTwoPathsFingerprintAlike() throws {
        let one     = try writeBinary(named: "toolA", contents: "binary",
                                      modified: Date(timeIntervalSince1970: 1_000))
        let another = try writeBinary(named: "toolB", contents: "binary",
                                      modified: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(toolBinaryContentFingerprint(ofFileAt: one),
                       toolBinaryContentFingerprint(ofFileAt: another))
    }

    func test_thereIsNoFingerprintOfWhatIsNotAFile() throws {
        XCTAssertNil(toolBinaryContentFingerprint(ofFileAt: folder.appendingPathComponent("absent").path))
        XCTAssertNil(toolBinaryContentFingerprint(ofFileAt: folder.path), "a folder is not a binary")
    }

    /// Hashing hundreds of megabytes is worth doing once. Two names for one binary — the
    /// Apple toolchain's `swiftc` and `swift` both point at `swift-frontend` — ask once
    /// between them, and the answer a process gives is the one it first read.
    func test_theFingerprintIsReadOncePerBinaryPerProcess() throws {
        let target = try writeBinary(named: "memoised-frontend", contents: "frontend",
                                     modified: Date(timeIntervalSince1970: 1_000))
        let link = folder.appendingPathComponent("memoised-driver")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "memoised-frontend")

        let first = toolBinaryFingerprint(ofFileAt: target)
        XCTAssertNotNil(first)
        XCTAssertEqual(toolBinaryFingerprint(ofFileAt: link.path), first,
                       "two names for one binary are one question")

        try writeBinary(named: "memoised-frontend", contents: "a different frontend",
                        modified: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(toolBinaryFingerprint(ofFileAt: target), first,
                       "the snapshot a process took is the one it keeps")
        XCTAssertNotEqual(toolBinaryContentFingerprint(ofFileAt: target), first,
                          "and the bytes on disk have moved on")
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

        XCTAssertNoThrow(try registry.tool(descriptor: descriptor(recursiveHash: nil), namespace: "fake.tool"))
    }

    /// And a stale fingerprint in a config file does not un-select it either: the four
    /// identity fields are the whole question.
    func test_aStaleFingerprintInAConfigurationSelectsTheInstalledToolToo() throws {
        let registry = ToolRunnerRegistry()
        registry.registerTool(descriptor: descriptor(recursiveHash: "fingerprint"), toolExecutor: NoTool())

        XCTAssertNoThrow(try registry.tool(descriptor: descriptor(recursiveHash: "a fingerprint of something else"),
                                           namespace:  "fake.tool"))
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
