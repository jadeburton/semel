//
//  Metadata.swift
//  SemelDatabaseModels
//

import Foundation
import GRDB

/// One row per fact about the database as a whole — which Semel version built the graph,
/// for instance. Kept in the graph's own database so the fact and the state it describes
/// commit together.
public struct Metadata: Codable, FetchableRecord, PersistableRecord, Equatable {
    public enum Columns {
        public static let key   = Column(CodingKeys.key)
        public static let value = Column(CodingKeys.value)
    }

    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key   = key
        self.value = value
    }

    public static let databaseTableName = "Metadata"

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: databaseTableName, options: .ifNotExists) { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
    }
}

public struct MetadataDataAccess: DataAccessType {
    public weak var databaseLayer: DatabaseLayer?

    public init(databaseLayer: DatabaseLayer) {
        self.databaseLayer = databaseLayer
    }

    public func select(key: String) throws -> String? {
        try read { db in
            try db.cachedValue("SELECT value FROM Metadata WHERE key = ?", arguments: [key])
        }
    }

    /// Every key under `prefix`, sorted, so a family of rows (`manifestDirty/<id>`) can be
    /// walked in one query.
    public func selectKeys(withPrefix prefix: String) throws -> [String] {
        try read { db in
            try db.cachedValues("SELECT key FROM Metadata WHERE key LIKE ? ORDER BY key", arguments: [prefix + "%"])
        }
    }

    /// One statement where `save` is an update and then, for a new key, an insert: a push
    /// marks the folder of every file it records, most of them for the first time.
    public func upsert(key: String, value: String) throws {
        try write { db in
            try db.cachedExecute("""
                INSERT INTO Metadata (key, value) VALUES (?, ?)
                ON CONFLICT (key) DO UPDATE SET value = excluded.value
                """, arguments: [key, value])
        }
    }

    public func delete(key: String) throws {
        try write { db in
            try db.cachedExecute("DELETE FROM Metadata WHERE key = ?", arguments: [key])
        }
    }

    /// Writes the row only when `key` has none, and says whether it did: the first record
    /// of a path in a batch's journal is the one that stands.
    @discardableResult
    public func insertIfAbsent(key: String, value: String) throws -> Bool {
        try write { db in
            try db.cachedExecute("INSERT OR IGNORE INTO Metadata (key, value) VALUES (?, ?)", arguments: [key, value])
            return db.changesCount > 0
        }
    }

    /// Every row whose key starts with `prefix`, compared byte for byte rather than with
    /// `LIKE`: the rest of such a key is a path or a name a person chose, and `%` or `_` in
    /// it must not match anything but itself. Sorted by key.
    public func selectEntries(withExactPrefix prefix: String) throws -> [(key: String, value: String)] {
        try read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT key, value FROM Metadata WHERE substr(key, 1, ?) = ? ORDER BY key
                """, arguments: [prefix.unicodeScalars.count, prefix])
            return rows.map { (key: $0["key"], value: $0["value"]) }
        }
    }

    /// Removes every row whose key starts with `prefix`, compared as `selectEntries` does.
    public func deleteAll(withExactPrefix prefix: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM Metadata WHERE substr(key, 1, ?) = ?", arguments: [prefix.unicodeScalars.count, prefix])
        }
    }
}
