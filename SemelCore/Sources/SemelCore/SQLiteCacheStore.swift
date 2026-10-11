// SQLiteCacheStore.swift
// SemelCore
//
// The engine's cache store: `SemelCache`'s `SQLiteCacheStore` over the cache's tables in the
// graph's database. Beside what the store answers for any database that holds those tables
// is what only an engine can ask — what the input file system holds, which key a node's
// outputs came from — because those rows join the graph's.

import Foundation
import GRDB
import SemelCache
import SemelDatabaseModels
import SemelNodeKit

extension DatabaseLayer {

    /// The cache's rows in this database. A value per use, as cheap as the accessors the
    /// layer holds: it keeps the layer weakly and nothing else.
    public var cacheEntry: SQLiteCacheStore {
        SQLiteCacheStore(database: self)
    }
}

extension SQLiteCacheStore {

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
        try write { connection in
            let nowHeld = try Int.fetchOne(connection, sql: """
                SELECT COALESCE(SUM(bytes), 0) FROM CacheObject WHERE heldByInput = 0 AND hash IN (\(held))
                """, arguments: kinds) ?? 0
            let noLongerHeld = try Int.fetchOne(connection, sql: """
                SELECT COALESCE(SUM(bytes), 0) FROM CacheObject WHERE heldByInput = 1 AND hash NOT IN (\(held))
                """, arguments: kinds) ?? 0
            // An empty object's flag decides no byte anywhere, so only bytes are worth a write.
            guard nowHeld != 0 || noLongerHeld != 0 else {
                return
            }
            try connection.execute(sql: "UPDATE CacheObject SET heldByInput = 1 WHERE heldByInput = 0 AND hash IN (\(held))",
                           arguments: kinds)
            try connection.execute(sql: "UPDATE CacheObject SET heldByInput = 0 WHERE heldByInput = 1 AND hash NOT IN (\(held))",
                           arguments: kinds)
            try connection.execute(sql: "UPDATE CacheAccount SET bytes = bytes - ? + ? WHERE id = 1",
                           arguments: [nowHeld, noLongerHeld])
        }
    }

    // MARK: Which key a node's outputs came from

    /// Records the key whose build the node's outputs now are, or that they are no cached
    /// build's: what keeps eviction off an entry the graph is standing on.
    public func recordKey(_ cacheKey: String?, forNodeID nodeID: ObjectID) throws {
        try write { connection in
            guard let cacheKey else {
                try connection.cachedExecute("DELETE FROM NodeCacheKey WHERE nodeID = ?", arguments: [nodeID])
                return
            }
            try connection.cachedExecute("""
                INSERT INTO NodeCacheKey (nodeID, cacheKey) VALUES (?, ?)
                ON CONFLICT (nodeID) DO UPDATE SET cacheKey = excluded.cacheKey
                """, arguments: [nodeID, cacheKey])
        }
    }

    public func recordedKey(forNodeID nodeID: ObjectID) throws -> String? {
        try read { connection in
            try connection.cachedValue("SELECT cacheKey FROM NodeCacheKey WHERE nodeID = ?", arguments: [nodeID])
        }
    }
}
