//
//  SDKFingerprintTests.swift
//  SemelNodeKitTests
//
//  B-47. The SDK's contents reach the graph as a fingerprint of every file's path, size and
//  modification time. These pin the fingerprint on a stand-in directory — the real SDK is
//  too big and too shared to edit in a test — and that a process walks one SDK once.
//

@testable import SemelNodeKit
import Foundation
import XCTest

final class SDKFingerprintTests: XCTestCase {

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

    override func tearDownWithError() throws {
        sdkFingerprintProvider = savedProvider
        try? FileManager.default.removeItem(at: sdk.deletingLastPathComponent())
        sdk = nil
        try super.tearDownWithError()
    }

    private func write(_ relativePath: String, _ content: String) throws {
        try content.write(to: sdk.appendingPathComponent(relativePath), atomically: true, encoding: .utf8)
    }

    private func fingerprint() throws -> String {
        try XCTUnwrap(sdkContentFingerprint(ofDirectory: sdk))
    }

    // MARK: - What the fingerprint covers

    func test_theSameTreeFingerprintsTheSameTwice() throws {
        XCTAssertEqual(try fingerprint(), try fingerprint())
        XCTAssertEqual(try fingerprint().count, 64, "a SHA-256 hex digest")
    }

    func test_editingAFileChangesTheFingerprint() throws {
        let before = try fingerprint()

        try write("usr/include/stdio.h", "int printf(const char *, ...);\nint puts(const char *);\n")

        XCTAssertNotEqual(before, try fingerprint(), "a changed header is a different SDK")
    }

    /// A file of another size is a different tree even when its modification time is put
    /// back as it was: the walk reads no content, so the size is what sees the edit.
    func test_aChangedSizeChangesTheFingerprint() throws {
        let header   = sdk.appendingPathComponent("usr/include/stdio.h")
        let modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: header.path)[.modificationDate] as? Date)
        let before   = try fingerprint()

        try write("usr/include/stdio.h", "int printf(const char *, ...); // and a longer line\n")
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: header.path)

        XCTAssertNotEqual(before, try fingerprint())
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

    // MARK: - Once per process

    /// Every compile, preprocess and link asks; the tree is walked the first time, and a
    /// second name for it — the symlink xcrun reports — is the same walk.
    func test_aProcessWalksOneSDKOnce() throws {
        var walks = 0
        let memo = SDKFingerprints { directory in
            walks += 1
            return sdkContentFingerprint(ofDirectory: directory)
        }
        let link = sdk.deletingLastPathComponent().appendingPathComponent("MacOSX26.5.sdk")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sdk)

        let first = memo.fingerprint(ofSDKAtPath: sdk.path)
        try write("usr/include/stdlib.h", "void *malloc(unsigned long);\n")
        let second  = memo.fingerprint(ofSDKAtPath: sdk.path)
        let throughTheLink = memo.fingerprint(ofSDKAtPath: link.path)

        XCTAssertEqual(walks, 1)
        XCTAssertEqual(first, second, "the answer cannot change mid-build, so a process keeps the first")
        XCTAssertEqual(first, throughTheLink)
    }

    /// Two SDKs are two walks.
    func test_twoSDKsAreTwoWalks() throws {
        var walks = 0
        let memo = SDKFingerprints { directory in
            walks += 1
            return sdkContentFingerprint(ofDirectory: directory)
        }
        let other = sdk.deletingLastPathComponent().appendingPathComponent("iPhoneSimulator.sdk")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        _ = memo.fingerprint(ofSDKAtPath: sdk.path)
        _ = memo.fingerprint(ofSDKAtPath: other.path)

        XCTAssertEqual(walks, 2)
    }

    // MARK: - As cache-key material

    func test_theMaterialNamesTheSDKAndCarriesItsFingerprint() {
        sdkFingerprintProvider = { path in "fp-of-\(path)" }

        XCTAssertEqual(sdkCacheKeyMaterial(sdkNamed: "macosx", atPath: "/SDKs/MacOSX.sdk"), "sdk=macosx:fp-of-/SDKs/MacOSX.sdk")
    }

    func test_noSDKMeansNoMaterial() {
        sdkFingerprintProvider = { _ in nil }

        XCTAssertNil(sdkCacheKeyMaterial(sdkNamed: "macosx", atPath: "/SDKs/MacOSX.sdk"))
    }

    // MARK: - The machine's SDK

    /// The machine's real SDK: the walk succeeds, is stable, and costs what B-47 measured —
    /// printed so a run shows it, not asserted, because a loaded machine is slower.
    func test_theRealSDKFingerprintsStably() throws {
        let path = try XCTUnwrap(MachineQuery.output(of: "/usr/bin/xcrun", ["--show-sdk-path"]), "this machine has no macOS SDK")
        let started = Date()
        let first   = try XCTUnwrap(sdkContentFingerprint(ofDirectory: URL(fileURLWithPath: path)))
        let walked  = Date().timeIntervalSince(started)
        let second  = try XCTUnwrap(sdkContentFingerprint(ofDirectory: URL(fileURLWithPath: path)))
        let again   = Date().timeIntervalSince(started) - walked

        print("SDK fingerprint of \(path): first walk \(String(format: "%.2f", walked)) s, second \(String(format: "%.2f", again)) s")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64, "a SHA-256 hex digest")
    }
}
