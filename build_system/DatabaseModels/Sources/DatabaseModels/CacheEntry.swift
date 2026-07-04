import Foundation
import CryptoKit
import GRDB

public struct CacheEntry: Codable, FetchableRecord, PersistableRecord {
    public var hash: String
    public var content: [UInt8]
    public var cost: Int
    public var timestamp: Date

    public init(hash: String, content: [UInt8], cost: Int, timestamp: Date) {
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
        print("WARNING: expensive selectAllCacheEntries call")
        return try read { db in try CacheEntry.fetchAll(db) }
    }

    public func select(hash: String) throws -> CacheEntry? {
        try read { db in
            try CacheEntry.filter(Column("hash") == hash).fetchOne(db)
        }
    }

    public func insert(_ cacheEntry: CacheEntry) throws {
        try write { db in try cacheEntry.insert(db) }
    }

    public func delete(hash: String) throws -> Bool {
        try write { db in
            try CacheEntry.filter(Column("hash") == hash).deleteAll(db) > 0
        }
    }

    // TODO: method to update the timestamp and cost of an existing row
    // TODO: method to get number of rows
    // TODO: method to delete rows until the total number of rows reaches a certain limit. The rows deleted should be
    // the oldest ones based on the timestamp column.
}

extension CacheEntry: CustomStringConvertible {
    public var description: String {
        "CacheEntry hash=0x\(hash), size=\(content.count) byte(s), content=0x\(content.prefix(16).asHex())\(content.count > 16 ? "..." : "")"
    }
}
