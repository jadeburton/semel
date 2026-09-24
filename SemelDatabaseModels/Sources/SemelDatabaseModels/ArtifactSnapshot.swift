//
//  ArtifactSnapshot.swift
//  SemelDatabaseModels
//

import Foundation
import GRDB

/// One row per artifact the user has been told about: its path, and the content hash that
/// was last reported for it. The durable half of the settle diff — what a report at the
/// next settle is compared against.
///
/// In the graph's own database on purpose, for the reason `Metadata` is: a client told an
/// artifact appeared must be able to find it, so the report and the state it describes
/// commit together. A row is the *reported* hash and not the current one, which is what
/// makes a rebuild publishing the same bytes silent.
public struct ArtifactSnapshot: Codable, FetchableRecord, PersistableRecord, Equatable {
    public enum Columns {
        public static let path        = Column(CodingKeys.path)
        public static let contentHash = Column(CodingKeys.contentHash)
    }

    public var path: String
    public var contentHash: String

    public init(path: String, contentHash: String) {
        self.path        = path
        self.contentHash = contentHash
    }

    public static let databaseTableName = "ArtifactSnapshot"

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: databaseTableName, options: .ifNotExists) { t in
                t.primaryKey("path", .text)
                t.column("contentHash", .text).notNull()
            }
        }
    }
}

public struct ArtifactSnapshotDataAccess: DataAccessType {
    public weak var databaseLayer: DatabaseLayer?

    public init(databaseLayer: DatabaseLayer) {
        self.databaseLayer = databaseLayer
    }

    public func select(path: String) throws -> ArtifactSnapshot? {
        try read { db in
            try ArtifactSnapshot.filter(ArtifactSnapshot.Columns.path == path).fetchOne(db)
        }
    }

    /// Every row, in path order. The reconciliation the first settle of a launch runs is
    /// the only caller: the steady path compares the paths the write path touched, one
    /// lookup by primary key each.
    public func selectAll() throws -> [ArtifactSnapshot] {
        try read { db in
            try ArtifactSnapshot.order(ArtifactSnapshot.Columns.path).fetchAll(db)
        }
    }

    public func upsert(path: String, contentHash: String) throws {
        try write { db in
            try ArtifactSnapshot(path: path, contentHash: contentHash).save(db)
        }
    }

    public func delete(path: String) throws {
        _ = try write { db in
            try ArtifactSnapshot.filter(ArtifactSnapshot.Columns.path == path).deleteAll(db)
        }
    }
}
