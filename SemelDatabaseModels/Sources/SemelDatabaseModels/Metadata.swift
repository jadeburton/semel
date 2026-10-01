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
}
