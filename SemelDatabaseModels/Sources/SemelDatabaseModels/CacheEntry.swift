// CacheEntry.swift
// SemelDatabaseModels
//
// The cache's tables in the graph's database. The rows are here, with the schema every
// table of the database is created from; the queries over them are `SQLiteCacheStore` in
// `SemelCore`, which answers `SemelCache`'s `CacheStore` in the vocabulary the cache
// defines and this package, below the node kit, cannot import.

import Foundation
import GRDB

// MARK: - Rows

/// One cached build: its key, what it is a build of, what it cost, which settle last used
/// it, and the stored output itself.
///
/// `content` is the last column on purpose: SQLite reads a row's columns in order, and a
/// column after a blob that overflows its page costs a walk of the overflow chain. Every
/// query that sizes or orders the cache reads the columns before it and never the blob.
public struct CacheEntry: Codable, FetchableRecord, PersistableRecord {
    public var hash: String
    /// The node type the key was taken for, as its material names it: what `cache` lists
    /// and what an eviction report counts, without decoding an entry for it.
    public var nodeType: String
    /// How long the build took, in milliseconds. What eviction weighs bytes against, and
    /// what a remote cache will weigh a fetch against; it decides no value.
    public var cost: Int
    /// The ordinal of the last settle that wrote or read this entry (`CacheAccount.settle`).
    public var lastUse: Int
    public var content: Data

    public init(hash: String, nodeType: String, cost: Int, lastUse: Int, content: Data) {
        self.hash     = hash
        self.nodeType = nodeType
        self.cost     = cost
        self.lastUse  = lastUse
        self.content  = content
    }

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "CacheEntry", options: .ifNotExists) { table in
                table.column("hash", .text).notNull().primaryKey()
                table.column("nodeType", .text).notNull()
                table.column("cost", .integer).notNull()
                table.column("lastUse", .integer).notNull().indexed()
                table.column("content", .blob).notNull()
            }
            try db.create(table: "CacheObject", options: [.ifNotExists, .withoutRowID]) { table in
                table.column("hash", .text).notNull().primaryKey()
                table.column("bytes", .integer).notNull()
                table.column("holders", .integer).notNull()
                table.column("heldByInput", .boolean).notNull()
            }
            try db.create(table: "CacheEntryObject", options: [.ifNotExists, .withoutRowID]) { table in
                table.column("entryHash", .text).notNull()
                table.column("objectHash", .text).notNull()
                table.primaryKey(["entryHash", "objectHash"])
            }
            try db.create(indexOn: "CacheEntryObject", columns: ["objectHash"], options: .ifNotExists)
            try db.create(table: "CacheAccount", options: .ifNotExists) { table in
                table.primaryKey("id", .integer).check { $0 == 1 }
                table.column("bytes", .integer).notNull()
                table.column("settle", .integer).notNull()
                table.column("lastUsingSettle", .integer).notNull()
            }
            try db.execute(sql: "INSERT OR IGNORE INTO CacheAccount (id, bytes, settle, lastUsingSettle) VALUES (1, 0, 1, 0)")
            try db.create(table: "NodeCacheKey", options: .ifNotExists) { table in
                table.primaryKey("nodeID", .integer)
                table.column("cacheKey", .text).notNull().indexed()
            }
        }
    }
}

private extension Sequence<UInt8> {
    func asHex() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension CacheEntry: CustomStringConvertible {
    public var description: String {
        "CacheEntry hash=0x\(hash), size=\(content.count) byte(s), content=0x\(content.prefix(16).asHex())\(content.count > 16 ? "..." : "")"
    }
}
