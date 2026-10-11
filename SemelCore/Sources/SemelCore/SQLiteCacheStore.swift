// SQLiteCacheStore.swift
// SemelCore
//
// The engine's cache store: `SemelCache`'s `CacheStore` over the cache's tables in the
// graph's database. Beside the protocol it answers what only an engine can ask — which
// settle is closing, what the input file system holds, which key a node's outputs came
// from — because those rows join the graph's.

import Foundation
import GRDB
import SemelCache
import SemelDatabaseModels
import SemelNodeKit

extension DatabaseLayer {

    /// The cache's rows in this database. A value per use, as cheap as the accessors the
    /// layer holds: it keeps the layer weakly and nothing else.
    public var cacheEntry: SQLiteCacheStore {
        SQLiteCacheStore(databaseLayer: self)
    }
}

public struct SQLiteCacheStore: DataAccessType, CacheStore {
    public weak var databaseLayer: DatabaseLayer?

    public init(databaseLayer: DatabaseLayer) {
        self.databaseLayer = databaseLayer
    }

    // MARK: CacheStore

    public func content(hash: String) throws -> Data? {
        try read { db in
            try db.cachedValue("SELECT content FROM CacheEntry WHERE hash = ?", arguments: [hash])
        }
    }

    // MARK: Entries

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

    /// Stores the entry whether or not its key is already taken, with the objects it holds,
    /// stamped as used by the settle in progress. Replacing rather than refusing is what
    /// the cache path wants: a key is a build, and a row already under it is either the
    /// same build or one this Semel could not read, and in both cases the entry being
    /// written is the one worth keeping. An insert that refused would fail on a constraint
    /// the caller cannot act on.
    ///
    /// The running total moves by the objects no other entry held before: an object a
    /// second entry holds is counted once, when the first one stored it.
    public func save(hash: String, nodeType: String, cost: Int, content: Data, objects: [CachedObject]) throws {
        try write { db in
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

    public func delete(hash: String) throws -> Bool {
        try write { db in
            try unlink(entryHash: hash, db: db)
            try db.cachedExecute("DELETE FROM CacheEntry WHERE hash = ?", arguments: [hash])
            return db.changesCount > 0
        }
    }

    public func deleteAll() throws -> Bool {
        try write { db in
            try db.execute(sql: "DELETE FROM CacheEntryObject")
            try db.execute(sql: "DELETE FROM CacheObject")
            try db.execute(sql: "UPDATE CacheAccount SET bytes = 0 WHERE id = 1")
            return try CacheEntry.deleteAll(db) > 0
        }
    }

    /// Stamps the entry as used by the settle in progress: a hit.
    public func noteUse(hash: String) throws {
        try write { db in
            try db.cachedExecute("UPDATE CacheEntry SET lastUse = (SELECT settle FROM CacheAccount WHERE id = 1) WHERE hash = ?",
                                 arguments: [hash])
        }
    }

    public func count() throws -> Int {
        try read { db in try CacheEntry.fetchCount(db) }
    }

    /// The objects an entry holds, by hash, sorted.
    public func objects(ofEntry hash: String) throws -> [DataObjectHash] {
        try read { db in
            try db.cachedValues("SELECT objectHash FROM CacheEntryObject WHERE entryHash = ? ORDER BY objectHash", arguments: [hash])
        }
    }

    // MARK: Account

    public func account() throws -> CacheAccount {
        try read { db in
            guard let row = try db.cachedRows("SELECT bytes, settle, lastUsingSettle FROM CacheAccount WHERE id = 1").first else {
                throw DatabaseLayer.DatabaseError.cacheAccountMissing
            }
            return CacheAccount(bytes: row["bytes"], settle: row["settle"], lastUsingSettle: row["lastUsingSettle"])
        }
    }

    /// Ends the settle in progress as far as the cache is concerned: when it used an
    /// entry, it becomes the last settle that did and the next one gets the next ordinal.
    /// A settle that used nothing — a push of an unchanged file — leaves both alone, so
    /// "the last settle" stays the last one that built or hit something.
    public func closeSettle() throws {
        try write { db in
            try db.cachedExecute("""
                UPDATE CacheAccount SET lastUsingSettle = settle, settle = settle + 1
                WHERE id = 1 AND EXISTS (SELECT 1 FROM CacheEntry WHERE lastUse = CacheAccount.settle)
                """)
        }
    }

    /// Recounts which objects the input file system holds — a value on a port of a node
    /// of one of `inputKinds` — and moves the total by what changed. An object a push
    /// holds is the push's, not the cache's, however many entries hold it too.
    ///
    /// Not done as each entry is written: that would ask the graph about every object of
    /// every entry, with no index on a port's value to ask it through. Here it is one
    /// pass over the input file system's ports and one over the cache's objects, and a push
    /// between two passes leaves the total off by the objects it shares with an entry —
    /// a copy of a pushed file — until the next.
    public func refreshInputHolding(inputKinds: [UInt]) throws {
        guard !inputKinds.isEmpty else {
            return
        }
        let placeholders = inputKinds.map { _ in "?" }.joined(separator: ", ")
        let held = """
            SELECT port.dataObjectHash FROM OutputPort port JOIN Node node ON node.id = port.nodeID
            WHERE node.kind IN (\(placeholders)) AND port.dataObjectHash IS NOT NULL
            """
        let kinds = StatementArguments(inputKinds.map { Int64($0) })
        try write { db in
            let nowHeld = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(bytes), 0) FROM CacheObject WHERE heldByInput = 0 AND hash IN (\(held))
                """, arguments: kinds) ?? 0
            let noLongerHeld = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(bytes), 0) FROM CacheObject WHERE heldByInput = 1 AND hash NOT IN (\(held))
                """, arguments: kinds) ?? 0
            // An empty object's flag decides no byte anywhere, so only bytes are worth a write.
            guard nowHeld != 0 || noLongerHeld != 0 else {
                return
            }
            try db.execute(sql: "UPDATE CacheObject SET heldByInput = 1 WHERE heldByInput = 0 AND hash IN (\(held))",
                           arguments: kinds)
            try db.execute(sql: "UPDATE CacheObject SET heldByInput = 0 WHERE heldByInput = 1 AND hash NOT IN (\(held))",
                           arguments: kinds)
            try db.execute(sql: "UPDATE CacheAccount SET bytes = bytes - ? + ? WHERE id = 1",
                           arguments: [nowHeld, noLongerHeld])
        }
    }

    /// The total as the object rows add up, rather than as the account kept it: what a
    /// test, and a check, compare the running total with.
    public func bytesByObjectRows() throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM CacheObject WHERE heldByInput = 0") ?? 0
        }
    }

    /// Every entry with what it alone holds, its share of what it holds with entries no
    /// node stands on, and whether a node of the graph is keyed on it. Read from the
    /// account's rows only: nothing in the store is opened.
    public func sizes() throws -> [CacheEntrySize] {
        try read { db in
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

    // MARK: Which key a node's outputs came from

    /// Records the key whose build the node's outputs now are, or that they are no cached
    /// build's: what keeps eviction off an entry the graph is standing on.
    public func recordKey(_ cacheKey: String?, forNodeID nodeID: ObjectID) throws {
        try write { db in
            guard let cacheKey else {
                try db.cachedExecute("DELETE FROM NodeCacheKey WHERE nodeID = ?", arguments: [nodeID])
                return
            }
            try db.cachedExecute("""
                INSERT INTO NodeCacheKey (nodeID, cacheKey) VALUES (?, ?)
                ON CONFLICT (nodeID) DO UPDATE SET cacheKey = excluded.cacheKey
                """, arguments: [nodeID, cacheKey])
        }
    }

    public func recordedKey(forNodeID nodeID: ObjectID) throws -> String? {
        try read { db in
            try db.cachedValue("SELECT cacheKey FROM NodeCacheKey WHERE nodeID = ?", arguments: [nodeID])
        }
    }
}
