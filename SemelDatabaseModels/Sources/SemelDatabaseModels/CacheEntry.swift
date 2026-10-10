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
                table.column("limitBytes", .integer)
                table.column("settle", .integer).notNull()
                table.column("lastUsingSettle", .integer).notNull()
            }
            try db.execute(sql: "INSERT OR IGNORE INTO CacheAccount (id, bytes, limitBytes, settle, lastUsingSettle) VALUES (1, 0, NULL, 1, 0)")
            try db.create(table: "NodeCacheKey", options: .ifNotExists) { table in
                table.primaryKey("nodeID", .integer)
                table.column("cacheKey", .text).notNull().indexed()
            }
        }
    }
}

/// An object an entry holds in the store, with its size there.
public struct CachedObject: Equatable, Hashable {
    public let hash:  String
    public let bytes: Int

    public init(hash: String, bytes: Int) {
        self.hash  = hash
        self.bytes = bytes
    }
}

/// The cache as a whole: the running total of what it holds, the limit set for this home,
/// and the settle ordinals eviction reads.
///
/// The ordinals count settles, not time: `settle` is stamped on every entry a settle writes
/// or reads, and closing a settle that used the cache moves it on and records it as
/// `lastUsingSettle`. "Not used by the last settle" is then `lastUse < lastUsingSettle`,
/// whatever the clock says.
public struct CacheAccount: Codable, FetchableRecord, Equatable {
    /// Bytes of the objects the entries hold that the input file system does not, each
    /// object once. Kept current by every save and delete, and corrected for the input
    /// file system by `refreshInputHolding` (see there).
    public let bytes: Int
    /// Nil until a limit is set: the engine's default applies.
    public let limitBytes: Int?
    public let settle: Int
    public let lastUsingSettle: Int
}

/// An entry as eviction and `cache` see it: no content, and its size.
public struct CacheEntrySize: Equatable {
    public let hash:     String
    public let nodeType: String
    public let cost:     Int
    public let lastUse:  Int
    /// The bytes of the objects this entry holds and nothing else does: no other entry,
    /// and not the input file system. What evicting it alone would give back.
    public let bytes:    Int
    /// Its share of the objects it holds with other entries, none of which a node stands
    /// on: each such object's bytes divided among its holders, rounded up. Evicting the
    /// entry gives none of it back, but it leaves the others nearer to giving it all back,
    /// which is what lets two entries that share everything be evicted at all.
    public let sharedBytes: Int
    /// Whether a node of the graph records this key as the one its outputs came from.
    public let heldByNode: Bool

    public init(hash: String, nodeType: String, cost: Int, lastUse: Int, bytes: Int, sharedBytes: Int, heldByNode: Bool) {
        self.hash        = hash
        self.nodeType    = nodeType
        self.cost        = cost
        self.lastUse     = lastUse
        self.bytes       = bytes
        self.sharedBytes = sharedBytes
        self.heldByNode  = heldByNode
    }

    /// What eviction weighs the entry's cost against: what it alone holds and its share of
    /// what it holds with entries that may go too.
    public var weight: Int {
        bytes + sharedBytes
    }
}

// MARK: - Access

public struct CacheEntryDataAccess: DataAccessType {
    public weak var databaseLayer: DatabaseLayer?

    public init(databaseLayer: DatabaseLayer) {
        self.databaseLayer = databaseLayer
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
    public func objects(ofEntry hash: String) throws -> [String] {
        try read { db in
            try db.cachedValues("SELECT objectHash FROM CacheEntryObject WHERE entryHash = ? ORDER BY objectHash", arguments: [hash])
        }
    }

    // MARK: Account

    public func account() throws -> CacheAccount {
        try read { db in
            guard let account: CacheAccount = try db.cachedRecord(
                "SELECT bytes, limitBytes, settle, lastUsingSettle FROM CacheAccount WHERE id = 1") else {
                throw DatabaseLayer.DatabaseError.cacheAccountMissing
            }
            return account
        }
    }

    /// Stores the home's limit; nil returns it to the engine's default.
    public func setLimit(bytes: Int?) throws {
        try write { db in
            try db.cachedExecute("UPDATE CacheAccount SET limitBytes = ? WHERE id = 1", arguments: [bytes])
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
