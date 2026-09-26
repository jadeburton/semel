import Foundation
import CryptoKit
import GRDB

public struct CacheEntry: Codable, FetchableRecord, PersistableRecord {
    public var hash: String
    public var content: Data
    public var cost: Int
    public var timestamp: Date

    public init(hash: String, content: Data, cost: Int, timestamp: Date) {
        self.hash = hash
        self.content = content
        self.cost = cost
        self.timestamp = timestamp
    }

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "CacheEntry", options: .ifNotExists) { t in
                t.column("hash", .text).notNull().primaryKey()
                t.column("content", .blob).notNull()
                t.column("cost", .integer).indexed().notNull()
                t.column("timestamp", .datetime).indexed().notNull()
            }
        }
    }
}

public struct CacheEntryDataAccess: DataAccessType {
    public weak var databaseLayer: DatabaseLayer?

    public init(databaseLayer: DatabaseLayer) {
        self.databaseLayer = databaseLayer
    }

    public func selectAll() throws -> [CacheEntry] {
        Debug.warn("expensive selectAllCacheEntries call")
        return try read { db in try CacheEntry.fetchAll(db) }
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

    /// Stores the entry whether or not its key is already taken. Replacing rather than
    /// refusing is what the cache path wants: a key is a build, and a row already under it
    /// is either the same build or one this Semel could not read, and in both cases the
    /// entry being written is the one worth keeping. An insert that refused would fail on
    /// a constraint the caller cannot act on.
    public func save(_ cacheEntry: CacheEntry) throws {
        try write { db in try cacheEntry.save(db) }
    }

    public func delete(hash: String) throws -> Bool {
        try write { db in
            try CacheEntry.filter(Column("hash") == hash).deleteAll(db) > 0
        }
    }

    public func deleteAll() throws -> Bool {
        try write { db in
            try CacheEntry.deleteAll(db) > 0
        }
    }

    public func updateTimestampAndCost(hash: String, cost: Int, timestamp: Date) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE CacheEntry SET cost = ?, timestamp = ? WHERE hash = ?",
                arguments: [cost, timestamp, hash])
        }
    }

    public func count() throws -> Int {
        try read { db in try CacheEntry.fetchCount(db) }
    }

    /// Deletes the oldest rows (by timestamp) until the total count is at or below `limit`.
    /// Returns the number of rows deleted.
    @discardableResult
    public func trimToLimit(_ limit: Int) throws -> Int {
        try write { db in
            let total = try CacheEntry.fetchCount(db)
            let excess = total - limit
            guard excess > 0 else {
                return 0
            }
            try db.execute(
                sql: """
                     DELETE FROM CacheEntry
                     WHERE hash IN (
                         SELECT hash FROM CacheEntry ORDER BY timestamp ASC LIMIT ?
                     )
                     """,
                arguments: [excess])
            return excess
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
