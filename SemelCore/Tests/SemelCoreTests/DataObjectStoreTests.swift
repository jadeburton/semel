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
