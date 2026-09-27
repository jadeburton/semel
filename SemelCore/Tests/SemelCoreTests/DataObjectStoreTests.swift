//
//  DataObjectStoreTests.swift
//  semel_tests
//
//  The store is content-addressed, which means the name of every object is a claim about
//  its bytes. Nothing checked that claim on the way out, so bit rot, a truncated write or
//  a hand-edited store were all indistinguishable from correct data — and a build made
//  from them looks entirely successful.
//

@testable import SemelCore
import Foundation
import XCTest
import SemelNodeKit

final class DataObjectStoreTests: SemelCoreTestCase {

    private var store: DataObjectStore { DataObjectStore.shared }

    // MARK: - Helpers

    /// Rewrites an object's file behind the store's back, as a failing disk would.
    /// Stored objects are made read-only, so the mode has to be relaxed first — which is
    /// itself worth knowing: the store already defends against accidental overwriting,
    /// just not against the bytes changing underneath it.
    private func tamper(with hash: String, to bytes: [UInt8]) throws {
        let url = store.objectURL(hash: hash)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try Data(bytes).write(to: url)
    }

    // MARK: - Round trip

    func test_anIntactObjectReadsBackUnchanged() throws {
        let content = [UInt8]("the quick brown fox jumps over the lazy dog".utf8)
        let hash = try content.intern()

        XCTAssertEqual(try store.read(hash: hash), content)
    }

    func test_aMissingObjectReadsAsNil() throws {
        XCTAssertNil(try store.read(hash: String(repeating: "a", count: 64)))
    }

    // MARK: - Storing a file where it lies (B-116)

    private func temporaryFile(holding bytes: [UInt8]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-store-tests-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    /// A file is filed under the hash its bytes would intern to — the two ways in are
    /// one store — and reads back as those bytes, read-only, like any object.
    func test_aFileIsStoredUnderTheSameHashAsItsBytes() throws {
        let content = [UInt8]((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let file = try temporaryFile(holding: content)
        defer { try? FileManager.default.removeItem(at: file) }

        let hash = try store.store(fileAt: file)

        XCTAssertEqual(hash, Sha256.hash(content))
        XCTAssertEqual(try store.read(hash: hash), content)
        let mode = try FileManager.default.attributesOfItem(atPath: store.objectURL(hash: hash).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o444)
    }

    /// The two rules `intern()` applies hold for a file too: nothing is the empty hash,
    /// and an object no longer than a digest is filed under its own hex.
    func test_anEmptyFileAndAShortFileAreFiledAsTheirBytesWouldBe() throws {
        let empty = try temporaryFile(holding: [])
        let short = try temporaryFile(holding: [UInt8]("short".utf8))
        defer {
            try? FileManager.default.removeItem(at: empty)
            try? FileManager.default.removeItem(at: short)
        }

        XCTAssertEqual(try store.store(fileAt: empty), "")
        XCTAssertEqual(try store.store(fileAt: short), try [UInt8]("short".utf8).intern())
        XCTAssertEqual(try store.read(hash: try store.store(fileAt: short)), [UInt8]("short".utf8))
    }

    /// The object is the store's, not a view of the caller's file: a tool's sandbox is
    /// deleted after the run, and a source rewritten afterwards must not reach into the
    /// store — which is what a clone's copy-on-write promises and a copy trivially keeps.
    func test_theStoredObjectIsIndependentOfTheSourceFile() throws {
        let content = [UInt8]("the source file, before anything happens to it".utf8)
        let file = try temporaryFile(holding: content)
        let hash = try store.store(fileAt: file)

        try Data("the source file, rewritten in place after storing".utf8).write(to: file)
        XCTAssertEqual(try store.read(hash: hash), content, "rewriting the source must not change the object")

        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try store.read(hash: hash), content, "deleting the source must not lose the object")
    }

    /// A second store of the same content — from a file or from bytes — finds the object
    /// there and changes nothing.
    func test_storingTheSameContentAgainIsANoOp() throws {
        let content = [UInt8]("content that arrives twice, once each way".utf8)
        let file = try temporaryFile(holding: content)
        defer { try? FileManager.default.removeItem(at: file) }

        let fromBytes = try content.intern()
        let fromFile = try store.store(fileAt: file)
        let again = try store.store(fileAt: file)

        XCTAssertEqual(fromBytes, fromFile)
        XCTAssertEqual(fromFile, again)
        XCTAssertEqual(try store.read(hash: fromFile), content)
    }

    // MARK: - Corruption

    /// The whole point: the bytes no longer hash to the name they are filed under.
    func test_anObjectWhoseBytesHaveChangedIsRejected() throws {
        let hash = try [UInt8]("the quick brown fox jumps over the lazy dog".utf8).intern()
        try tamper(with: hash, to: [UInt8]("the quick brown fox jumps over the lazy cat".utf8))

        XCTAssertThrowsError(try store.read(hash: hash)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains(hash), "should name the object, got \(message)")
        }
    }

    func test_aTruncatedObjectIsRejected() throws {
        let hash = try [UInt8](repeating: 7, count: 4096).intern()
        try tamper(with: hash, to: [UInt8](repeating: 7, count: 2048))

        XCTAssertThrowsError(try store.read(hash: hash))
    }

    /// Objects of 32 bytes or fewer are filed under their own hex rather than a digest —
    /// `Sha256.hash` returns the data itself when it is shorter than its hash. They must
    /// still be verified, not waved through because the check looks trivial.
    func test_aShortObjectIsVerifiedToo() throws {
        let hash = try [UInt8]("short".utf8).intern()
        try tamper(with: hash, to: [UInt8]("wrong".utf8))

        XCTAssertThrowsError(try store.read(hash: hash))
    }

    /// Corruption and absence must not look the same. Treating a corrupt object as
    /// missing would quietly rebuild it and never report that the store is damaged.
    func test_corruptionIsDistinguishedFromAbsence() throws {
        let hash = try [UInt8]("some content that is definitely longer than a digest".utf8).intern()
        try tamper(with: hash, to: [UInt8]("tampered".utf8))

        XCTAssertNil(try store.read(hash: String(repeating: "b", count: 64)))
        XCTAssertThrowsError(try store.read(hash: hash))
    }

    /// The message has to be actionable: a corrupt store is fixed by deleting the object
    /// so it is rebuilt, and that requires knowing which file.
    func test_theCorruptionErrorNamesWhatToDelete() throws {
        let hash = try [UInt8]("content long enough to be digested properly".utf8).intern()
        try tamper(with: hash, to: [UInt8]("nope".utf8))

        XCTAssertThrowsError(try store.read(hash: hash)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains(store.objectURL(hash: hash).path),
                          "should name the file on disk, got \(message)")
        }
    }
}
