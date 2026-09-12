//
//  SDKFingerprintTests.swift
//  SemelSwiftTests
//

@testable import SemelSwift
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-47, the wide half. The SDK's contents reach the Swift tools' cache key as a
/// fingerprint of every file's path, size and modification time. These pin the fingerprint
/// on a stand-in directory — the real SDK is too big and too shared to edit in a test.
final class SDKFingerprintTests: SemelSwiftTestCase {

    private var sdk: URL!
    private var savedProvider: ((String) -> String?)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedProvider = sdkFingerprintProvider
        sdk = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-sdk-tests/\(UUID().uuidString)/MacOSX.sdk", isDirectory: true)
        try FileManager.default.createDirectory(at: sdk.appendingPathComponent("usr/include"),
                                                withIntermediateDirectories: true)
        try write("usr/include/stdio.h", "int printf(const char *, ...);\n")
        try write("SDKSettings.json", "{\"Version\": \"26.5\"}\n")
    }

    override func tearDown() {
        sdkFingerprintProvider = savedProvider
        sdk = nil
        super.tearDown()
    }

    private func write(_ relativePath: String, _ content: String) throws {
        try content.write(to: sdk.appendingPathComponent(relativePath), atomically: true, encoding: .utf8)
    }

    private func fingerprint() throws -> String {
        try XCTUnwrap(sdkContentFingerprint(ofDirectory: sdk))
    }

    func test_theSameTreeFingerprintsTheSameTwice() throws {
        XCTAssertEqual(try fingerprint(), try fingerprint())
    }

    func test_editingAFileChangesTheFingerprint() throws {
        let before = try fingerprint()

        try write("usr/include/stdio.h", "int printf(const char *, ...);\nint puts(const char *);\n")

        XCTAssertNotEqual(before, try fingerprint(), "a changed header is a different SDK")
    }

    func test_addingAFileChangesTheFingerprint() throws {
        let before = try fingerprint()

        try write("usr/include/stdlib.h", "void *malloc(unsigned long);\n")

        XCTAssertNotEqual(before, try fingerprint())
    }

    /// Size and content can stay the same while the modification time moves: that is still
    /// a different tree to a compiler that reads the file, so it is a different fingerprint.
    func test_touchingAFileChangesTheFingerprint() throws {
        let before = try fingerprint()

        let header = sdk.appendingPathComponent("usr/include/stdio.h")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
                                              ofItemAtPath: header.path)

        XCTAssertNotEqual(before, try fingerprint())
    }

    /// The SDK path xcrun reports is a symlink (`MacOSX26.5.sdk -> MacOSX.sdk`); the
    /// fingerprint is of the tree, not of the name it was reached by.
    func test_aSymlinkToTheTreeFingerprintsTheSame() throws {
        let link = sdk.deletingLastPathComponent().appendingPathComponent("MacOSX26.5.sdk")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sdk)

        XCTAssertEqual(try fingerprint(), sdkContentFingerprint(ofDirectory: link))
    }

    func test_aMissingDirectoryHasNoFingerprint() {
        XCTAssertNil(sdkContentFingerprint(ofDirectory: sdk.appendingPathComponent("nowhere")))
    }

    // MARK: - Reaching the cache key

    /// A process input carrying only a configuration, which is all the material reads.
    private func input(configuration: String) throws -> ProcessInput {
        ProcessInput(inputValues: [SwiftCompiler.configuration: ["config": .value(try configuration.intern())]])
    }

    /// Both nodes that pass `-sdk` contribute the fingerprint, and nothing else about their
    /// key is involved here — the material is the same string for both. The SDK name is
    /// part of it, so two SDKs that happened to fingerprint alike would still not share.
    func test_theSwiftCompilerAndLinkerContributeTheFingerprintAsCacheKeyMaterial() throws {
        sdkFingerprintProvider = { _ in "0123abcd" }

        let compiler = try SwiftCompiler(thisNode: NodeRecord(id: 1, kind: SwiftCompiler.kind))
        let linker   = try SwiftLinker(thisNode: NodeRecord(id: 2, kind: SwiftLinker.kind))

        XCTAssertEqual(try compiler.cacheKeyMaterial(input: try input(configuration: "")), "sdk=macosx:0123abcd")
        XCTAssertEqual(try linker.cacheKeyMaterial(input: try input(configuration: "")),   "sdk=macosx:0123abcd")
    }

    /// The fingerprint is of the SDK the configuration names, not always macOS's.
    func test_theMaterialIsForTheConfiguredSDK() throws {
        sdkFingerprintProvider = { name in "fp-\(name)" }

        let compiler = try SwiftCompiler(thisNode: NodeRecord(id: 1, kind: SwiftCompiler.kind))

        XCTAssertEqual(try compiler.cacheKeyMaterial(input: try input(configuration: "sdk=iphonesimulator")),
                       "sdk=iphonesimulator:fp-iphonesimulator")
    }

    /// With no SDK on the machine there is nothing to fingerprint and nothing to add; the
    /// compile fails on its own for want of an SDK.
    func test_noSDKMeansNoMaterial() throws {
        sdkFingerprintProvider = { _ in nil }

        let compiler = try SwiftCompiler(thisNode: NodeRecord(id: 1, kind: SwiftCompiler.kind))

        XCTAssertNil(try compiler.cacheKeyMaterial(input: try input(configuration: "")))
    }

    /// The machine's real SDK: the walk succeeds and is stable. Two walks, about a second
    /// each — the per-process caching that spares production the second one is a private
    /// constant and is not exercised here.
    func test_theRealSDKFingerprintsStably() throws {
        let path = try XCTUnwrap(resolveSDKPath(), "this machine has no macOS SDK")
        let first  = try XCTUnwrap(sdkContentFingerprint(ofDirectory: URL(fileURLWithPath: path)))
        let second = try XCTUnwrap(sdkContentFingerprint(ofDirectory: URL(fileURLWithPath: path)))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64, "a SHA-256 hex digest")
    }
}
