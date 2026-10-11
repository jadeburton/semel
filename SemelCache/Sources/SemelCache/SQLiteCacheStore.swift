// SQLiteCacheStore.swift
// SemelCache
//
// `CacheStore` over the cache's tables in SQLite: the one implementation of them, for the two
// databases that hold them. The engine's graph database holds them beside the graph's
// tables; a cache server's index holds them alone. What only an engine asks — what the input
// file system holds, which key a node's outputs came from — joins the graph's tables and is
// `SemelCore`'s, beside this; everything here reads and writes the cache's tables and no
// other.
//
// Each query is written once against a `Database` connection, and once more as the
// `CacheStore` method that runs it in a read or a write of its own. A caller that wants
// several in one transaction — a cache server committing a batch of writes — runs the
// first kind inside a write it opened.

import Foundation
import GRDB
import SemelDatabaseModels
import SemelNodeKit

/// A database the cache's tables are in, as the store reaches it: a read and a write, each
/// handed a connection. The engine's `DatabaseLayer` is one, and its transactions carry
/// through; `CacheIndexDatabase` is a server's.
public protocol CacheDatabase: AnyObject {
    func read<T>(_ block: (Database) throws -> T) throws -> T
    func write<T>(_ block: (Database) throws -> T) throws -> T
}

extension DatabaseLayer: CacheDatabase {}

/// Why the cache's tables could not be asked.
public enum SQLiteCacheStoreError: Error, Equatable, CustomStringConvertible {
    /// The store outlived the database it was made over.
    case databaseReleased
    /// The cache's one account row is missing: the tables are created with it, so a database
    /// without it was damaged by hand.
    case accountMissing

    public var description: String {
        switch self {
        case .databaseReleased:
            return "the cache store was used after its database was closed"
        case .accountMissing:
            return "the cache's account row is missing from its database"
        }
    }
}

public struct SQLiteCacheStore: CacheStore {

    /// Held weakly: the engine's layer holds nothing of the store, and a store kept past
    /// its database must fail rather than keep the database open.
    public weak var database: (any CacheDatabase)?

    public init(database: any CacheDatabase) {
        self.database = database
    }

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try requireDatabase().read(block)
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try requireDatabase().write(block)
    }

    private func requireDatabase() throws -> any CacheDatabase {
        guard let database else {
            throw SQLiteCacheStoreError.databaseReleased
        }
        return database
    }

    // MARK: - CacheStore

    public func content(hash: String) throws -> Data? {
        try read { db in try content(hash: hash, in: db) }
    }

    public func save(hash: String, nodeType: String, cost: Int, content: Data, objects: [CachedObject]) throws {
        try write { db in try save(hash: hash, nodeType: nodeType, cost: cost, content: content, objects: objects, in: db) }
    }

    public func noteUse(hash: String) throws {
        try write { db in try noteUse(hash: hash, in: db) }
    }

    public func delete(hash: String) throws -> Bool {
        try write { db in try delete(hash: hash, in: db) }
    }

    public func account() throws -> CacheAccount {
        try read { db in try account(in: db) }
    }

    public func sizes() throws -> [CacheEntrySize] {
        try read { db in try sizes(in: db) }
    }

    public func objects(ofEntry hash: String) throws -> [DataObjectHash] {
        try read { db in
            try db.cachedValues("SELECT objectHash FROM CacheEntryObject WHERE entryHash = ? ORDER BY objectHash", arguments: [hash])
        }
    }

    // MARK: - The rest of the store, as a call

    public func closeSettle() throws {
        try write { db in try closeSettle(in: db) }
    }

    public func deleteAll() throws -> Bool {
        try write { db in try deleteAll(in: db) }
    }

    public func selectAll() throws -> [CacheEntry] {
        Debug.warn("expensive selectAllCacheEntries call")
        return try read { db in try CacheEntry.fetchAll(db) }
    }

    /// Every entry's content, without the rest of the row: what the collector decodes for
    /// the objects a cached build refers to (B-14). Each is a small JSON document.
    public func selectAllContent() throws -> [Data] {
        try read { db in try Data.fetchAll(db, sql: "SELECT content FROM CacheEntry ORDER BY hash") }
    }

    /// Every entry's key, without its content. A caller inspecting the keys would
    /// otherwise pull every cached build through memory to read a column of hex.
    public func selectAllHashes() throws -> [String] {
        try read { db in try String.fetchAll(db, sql: "SELECT hash FROM CacheEntry ORDER BY hash") }
    }

    public func select(hash: String) throws -> CacheEntry? {
        try read { db in
            try CacheEntry.filter(Column("hash") == hash).fetchOne(db)
        }
    }

    public func count() throws -> Int {
        try read { db in try CacheEntry.fetchCount(db) }
    }

    /// The total as the object rows add up, rather than as the account kept it: what a
    /// test, and a check, compare the running total with.
    public func bytesByObjectRows() throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM CacheObject WHERE heldByInput = 0") ?? 0
        }
    }

    // MARK: - The queries, on a connection

    public func content(hash: String, in db: Database) throws -> Data? {
        try db.cachedValue("SELECT content FROM CacheEntry WHERE hash = ?", arguments: [hash])
    }

    /// Stores the entry whether or not its key is already taken, with the objects it holds,
    /// stamped as used by the settle in progress. Replacing rather than refusing is what
    /// the cache path wants: a key is a build, and a row already under it is either the
    /// same build or one this Semel could not read, and in both cases the entry being
    /// written is the one worth keeping. An insert that refused would fail on a constraint
    /// the caller cannot act on.
    ///
    /// The running total moves by the objects no other entry held before: an object a
    /// second entry holds is counted once, when the first one stored it.
    public func save(hash: String, nodeType: String, cost: Int, content: Data, objects: [CachedObject], in db: Database) throws {
        try unlink(entryHash: hash, db: db)
        try db.cachedExecute("""
            INSERT OR REPLACE INTO CacheEntry (hash, nodeType, cost, lastUse, content)
            VALUES (?, ?, ?, (SELECT settle FROM CacheAccount WHERE id = 1), ?)
            """, arguments: [hash, nodeType, cost, content])
        var added = 0
        for object in Set(objects).sorted(by: { $0.hash < $1.hash }) {
            try db.cachedExecute("INSERT INTO CacheEntryObject (entryHash, objectHash) VALUES (?, ?)",
                                 arguments: [hash, object.hash])
            try db.cachedExecute("UPDATE CacheObject SET holders = holders + 1 WHERE hash = ?", arguments: [object.hash])
            guard db.changesCount == 0 else {
                continue
            }
            try db.cachedExecute("INSERT INTO CacheObject (hash, bytes, holders, heldByInput) VALUES (?, ?, 1, 0)",
                                 arguments: [object.hash, object.bytes])
            added += object.bytes
        }
        try db.cachedExecute("UPDATE CacheAccount SET bytes = bytes + ? WHERE id = 1", arguments: [added])
    }

    /// Takes an entry's holds off its objects: one holder fewer each, and an object no
    /// entry holds any more leaves the account, and the total if it was counted there.
    private func unlink(entryHash: String, db: Database) throws {
        try db.cachedExecute("""
            UPDATE CacheAccount SET bytes = bytes - (
                SELECT COALESCE(SUM(object.bytes), 0)
                FROM CacheEntryObject link JOIN CacheObject object ON object.hash = link.objectHash
                WHERE link.entryHash = ? AND object.holders = 1 AND object.heldByInput = 0)
            WHERE id = 1
            """, arguments: [entryHash])
        try db.cachedExecute("""
            UPDATE CacheObject SET holders = holders - 1
            WHERE hash IN (SELECT objectHash FROM CacheEntryObject WHERE entryHash = ?)
            """, arguments: [entryHash])
        try db.cachedExecute("""
            DELETE FROM CacheObject
            WHERE holders = 0 AND hash IN (SELECT objectHash FROM CacheEntryObject WHERE entryHash = ?)
            """, arguments: [entryHash])
        try db.cachedExecute("DELETE FROM CacheEntryObject WHERE entryHash = ?", arguments: [entryHash])
    }

    public func delete(hash: String, in db: Database) throws -> Bool {
        try unlink(entryHash: hash, db: db)
        try db.cachedExecute("DELETE FROM CacheEntry WHERE hash = ?", arguments: [hash])
        return db.changesCount > 0
    }

    public func deleteAll(in db: Database) throws -> Bool {
        try db.execute(sql: "DELETE FROM CacheEntryObject")
        try db.execute(sql: "DELETE FROM CacheObject")
        try db.execute(sql: "UPDATE CacheAccount SET bytes = 0 WHERE id = 1")
        return try CacheEntry.deleteAll(db) > 0
    }

    /// Stamps the entry as used by the settle in progress: a hit.
    public func noteUse(hash: String, in db: Database) throws {
        try db.cachedExecute("UPDATE CacheEntry SET lastUse = (SELECT settle FROM CacheAccount WHERE id = 1) WHERE hash = ?",
                             arguments: [hash])
    }

    public func account(in db: Database) throws -> CacheAccount {
        guard let row = try db.cachedRows("SELECT bytes, settle, lastUsingSettle FROM CacheAccount WHERE id = 1").first else {
            throw SQLiteCacheStoreError.accountMissing
        }
        return CacheAccount(bytes: row["bytes"], settle: row["settle"], lastUsingSettle: row["lastUsingSettle"])
    }

    /// Ends the settle in progress as far as the cache is concerned: when it used an
    /// entry, it becomes the last settle that did and the next one gets the next ordinal.
    /// A settle that used nothing — a push of an unchanged file — leaves both alone, so
    /// "the last settle" stays the last one that built or hit something.
    public func closeSettle(in db: Database) throws {
        try db.cachedExecute("""
            UPDATE CacheAccount SET lastUsingSettle = settle, settle = settle + 1
            WHERE id = 1 AND EXISTS (SELECT 1 FROM CacheEntry WHERE lastUse = CacheAccount.settle)
            """)
    }

    /// Every entry with what it alone holds, its share of what it holds with entries no
    /// node stands on, and whether a node of the graph is keyed on it. Read from the
    /// account's rows only: nothing in the store is opened. A database with no graph has
    /// no row in `NodeCacheKey`, so there no entry is held by a node.
    public func sizes(in db: Database) throws -> [CacheEntrySize] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT entry.hash, entry.nodeType, entry.cost, entry.lastUse,
                   COALESCE(SUM(CASE WHEN object.holders = 1 AND object.heldByInput = 0 THEN object.bytes ELSE 0 END), 0) AS bytes,
                   COALESCE(SUM(CASE WHEN object.holders > 1 AND object.heldByInput = 0 AND NOT EXISTS (
                                         SELECT 1 FROM CacheEntryObject other
                                         JOIN NodeCacheKey nodeKey ON nodeKey.cacheKey = other.entryHash
                                         WHERE other.objectHash = object.hash)
                                     THEN (object.bytes + object.holders - 1) / object.holders ELSE 0 END), 0) AS sharedBytes,
                   EXISTS (SELECT 1 FROM NodeCacheKey nodeKey WHERE nodeKey.cacheKey = entry.hash) AS heldByNode
            FROM CacheEntry entry
            LEFT JOIN CacheEntryObject link ON link.entryHash = entry.hash
            LEFT JOIN CacheObject object ON object.hash = link.objectHash
            GROUP BY entry.hash
            ORDER BY entry.hash
            """)
        return rows.map { row in
            CacheEntrySize(hash: row["hash"], nodeType: row["nodeType"], cost: row["cost"], lastUse: row["lastUse"],
                           bytes: row["bytes"], sharedBytes: row["sharedBytes"], heldByNode: row["heldByNode"])
        }
    }
}
