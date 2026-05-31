import Foundation
import CryptoKit
import GRDB

public struct CacheEntry: Codable, FetchableRecord, PersistableRecord {
    public var hash: String
    public var content: [UInt8]

    public init(hash: String, content: [UInt8]) {
        self.hash = hash
        self.content = content
    }

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "CacheEntry", options: .ifNotExists) { t in
                t.column("hash", .text).notNull().primaryKey()
                t.column("content", .blob).notNull()
            }
        }
    }
}

extension DatabaseLayer {
    public func selectAllCacheEntries() throws -> [CacheEntry] {
        try dbQueue.read { db in
            try CacheEntry
                .fetchAll(db)
        }
    }

    public func selectCacheEntry(hash: String) throws -> CacheEntry? {
        try dbQueue.read { db in
            try CacheEntry.filter(Column("hash") == hash).fetchOne(db)
        }
    }

    public func insertCacheEntry(_ cacheEntry: CacheEntry) throws {
        try dbQueue.write { db in
            try cacheEntry.insert(db)
        }
    }

    public func deleteCacheEntry(hash: String) throws -> Bool {
        try dbQueue.write { db in
            try CacheEntry.filter(Column("hash") == hash).deleteAll(db) > 0
        }
    }
}

public extension CacheEntry {
    func description() -> String {
        "CacheEntry hash=0x\(hash), size=\(content.count) byte(s), content=0x\(content.prefix(16).asHex())\(content.count > 16 ? "..." : "")"
    }
}
