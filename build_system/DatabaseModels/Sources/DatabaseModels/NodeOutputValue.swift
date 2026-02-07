import Foundation
import GRDB

public struct NodeOutputValue: Codable, Identifiable, FetchableRecord, PersistableRecord {
    public enum Columns {
        public static let nodeID = Column(CodingKeys.nodeID)
        public static let port = Column(CodingKeys.port)
        public static let dataObjectID = Column(CodingKeys.dataObjectID)
    }

    public var id: ObjectID?
    public var nodeID: ObjectID
    public var port: UInt8
    public var dataObjectID: ObjectID

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "NodeOutputValue", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("nodeID", .integer).notNull()
                t.column("port", .integer).notNull()
                t.column("dataObjectID", .integer).notNull()
            }
        }
    }
}

extension NodeOutputValue {
    // Select all NodeOutputValues associated with the given Node
    public static func selectAllNodeOutputValues(nodeID: ObjectID, dbQueue: DatabaseQueue) throws -> [NodeOutputValue] {
        []
    }

    public static func insertOrReplaceNodeOutputValue(_ node: NodeOutputValue, dbQueue: DatabaseQueue) throws {
    }

    public static func deleteNodeOutputValue(nodeOutputValueID: ObjectID, dbQueue: DatabaseQueue) throws {
    }
}
