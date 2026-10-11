// SQLiteCacheStore+Index.swift
// SemelCache
//
// The store as a cache server keeps it: read whole into memory once, when the server starts,
// and written to afterwards in batches, each one transaction. The server answers from what
// it holds in memory, so the rows are where its index survives a restart, not where a
// request is answered from.

import Foundation
import GRDB
import SemelDatabaseModels
import SemelNodeKit

/// One write to the cache's tables, as a batch carries it.
public enum CacheIndexOperation: Equatable {
    /// `SQLiteCacheStore.save`: an entry and the objects it holds, replacing any under its key.
    case save(hash: String, nodeType: String, cost: Int, content: Data, objects: [CachedObject])
    /// A hit, stamped with the settle in progress.
    case noteUse(hash: String)
    case delete(hash: String)
    case deleteAll
    case closeSettle
}

/// Every entry of the store without its content, with the objects it holds: what an index
/// in memory is built from.
public struct CacheIndexRows: Equatable {

    public struct Entry: Equatable {
        public let hash: String
        public let cost: Int
        public let lastUse: Int
        /// The length of the stored content, which is not read.
        public let length: Int
        public let objects: [DataObjectHash]

        public init(hash: String, cost: Int, lastUse: Int, length: Int, objects: [DataObjectHash]) {
            self.hash    = hash
            self.cost    = cost
            self.lastUse = lastUse
            self.length  = length
            self.objects = objects
        }
    }

    public let entries: [Entry]
    public let account: CacheAccount

    public init(entries: [Entry], account: CacheAccount) {
        self.entries = entries
        self.account = account
    }
}

extension SQLiteCacheStore {

    /// Runs `operations` in order, in one transaction: a batch is on disk whole or not at
    /// all.
    public func apply(_ operations: [CacheIndexOperation]) throws {
        guard !operations.isEmpty else {
            return
        }
        try write { connection in
            for operation in operations {
                switch operation {
                case .save(let hash, let nodeType, let cost, let content, let objects):
                    try save(hash: hash, nodeType: nodeType, cost: cost, content: content, objects: objects, in: connection)
                case .noteUse(let hash):
                    try noteUse(hash: hash, in: connection)
                case .delete(let hash):
                    _ = try delete(hash: hash, in: connection)
                case .deleteAll:
                    _ = try deleteAll(in: connection)
                case .closeSettle:
                    try closeSettle(in: connection)
                }
            }
        }
    }

    /// Every entry with its objects and the account, in one read: two passes over the rows
    /// and nothing of any entry's content but its length.
    public func indexRows() throws -> CacheIndexRows {
        try read { connection in
            var objectsByEntry: [String: [DataObjectHash]] = [:]
            let links = try Row.fetchAll(connection, sql: "SELECT entryHash, objectHash FROM CacheEntryObject ORDER BY entryHash, objectHash")
            for link in links {
                objectsByEntry[link["entryHash"], default: []].append(link["objectHash"])
            }
            let rows = try Row.fetchAll(connection, sql: "SELECT hash, cost, lastUse, length(content) AS length FROM CacheEntry ORDER BY hash")
            let entries = rows.map { row -> CacheIndexRows.Entry in
                let hash: String = row["hash"]
                return CacheIndexRows.Entry(hash: hash, cost: row["cost"], lastUse: row["lastUse"], length: row["length"],
                                            objects: objectsByEntry[hash] ?? [])
            }
            return CacheIndexRows(entries: entries, account: try account(in: connection))
        }
    }
}
