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
            try Metadata.filter(Metadata.Columns.key == key).fetchOne(db)?.value
        }
    }

    public func upsert(key: String, value: String) throws {
        try write { db in
            try Metadata(key: key, value: value).save(db)
        }
    }

    public func delete(key: String) throws {
        _ = try write { db in
            try Metadata.filter(Metadata.Columns.key == key).deleteAll(db)
        }
    }
}
