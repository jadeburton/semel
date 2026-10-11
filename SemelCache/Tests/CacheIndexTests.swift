// CacheIndexTests.swift
// SemelCacheTests
//
// The cache's tables in a database of their own, as a cache server keeps them: a batch
// applied as one transaction, read back whole without any entry's content, and the file
// tuned to answer quickly without ever being left inconsistent.

import Foundation
import GRDB
import SemelCache
import SemelNodeKit
import XCTest

final class CacheIndexTests: XCTestCase {

    private let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("semel-cache-index-\(UUID().uuidString.prefix(8))", isDirectory: true)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func hex(_ digit: String) -> String {
        String(repeating: digit, count: 64)
    }

    func test_aBatchIsAppliedInOrderAndReadBackWithoutContent() throws {
        let database = try CacheIndexDatabase()
        let store = SQLiteCacheStore(database: database)

        try store.apply([
            .save(hash: hex("a"), nodeType: "", cost: 10, content: Data("first".utf8),
                  objects: [CachedObject(hash: "0a", bytes: 100), CachedObject(hash: "0b", bytes: 50)]),
            .save(hash: hex("b"), nodeType: "", cost: 20, content: Data("second, longer".utf8),
                  objects: [CachedObject(hash: "0b", bytes: 50)]),
            .closeSettle,
            .noteUse(hash: hex("b")),
            .delete(hash: hex("a")),
        ])

        let rows = try store.indexRows()
        XCTAssertEqual(rows.entries, [CacheIndexRows.Entry(hash: hex("b"), cost: 20, lastUse: 2, length: 14, objects: ["0b"])])
        XCTAssertEqual(rows.account, CacheAccount(bytes: 50, settle: 2, lastUsingSettle: 1))
        XCTAssertEqual(try store.content(hash: hex("b")), Data("second, longer".utf8))
        withExtendedLifetime(database) {}
    }

    /// Write-ahead, synced at checkpoints only, no checkpoint on commit: a crash can lose
    /// the last transactions and never leaves the file inconsistent.
    func test_anIndexOnDiskTradesDurabilityAndNeverConsistency() throws {
        let path = folder.appendingPathComponent("index.sqlite").path
        let database = try CacheIndexDatabase(filePath: path)

        let pragmas = try database.read { connection in
            (journal:    try String.fetchOne(connection, sql: "PRAGMA journal_mode"),
             sync:       try Int.fetchOne(connection, sql: "PRAGMA synchronous"),
             checkpoint: try Int.fetchOne(connection, sql: "PRAGMA wal_autocheckpoint"))
        }
        XCTAssertEqual(pragmas.journal, "wal")
        XCTAssertEqual(pragmas.sync, 1, "NORMAL, never OFF")
        XCTAssertEqual(pragmas.checkpoint, 0, "the owner checkpoints when idle")

        let store = SQLiteCacheStore(database: database)
        try store.apply([.save(hash: hex("c"), nodeType: "", cost: 1, content: Data("x".utf8), objects: [])])
        try database.checkpoint()
        XCTAssertEqual(try store.count(), 1)
    }
}
