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

extension DatabaseLayer {
    // Select all NodeOutputValues associated with the given Node
    public func selectAllNodeOutputValues(nodeID: ObjectID) throws -> [NodeOutputValue] {
        try dbQueue.read { db in
            try NodeOutputValue.filter(NodeOutputValue.Columns.nodeID == nodeID).fetchAll(db)
        }
    }

    public func selectNodeOutputValue(nodeID: ObjectID, port: UInt8) throws -> NodeOutputValue? {
        try dbQueue.read { db in
            try NodeOutputValue.filter(NodeOutputValue.Columns.nodeID == nodeID &&
                                       NodeOutputValue.Columns.port == port).fetchOne(db)
        }
    }

    public func insertOrReplaceNodeOutputValue(_ nodeOutputValue: NodeOutputValue) throws {
        try dbQueue.write { db in
            try nodeOutputValue.save(db)
        }
    }

    public func deleteNodeOutputValue(nodeOutputValueID: ObjectID) throws -> Bool {
        try dbQueue.write { db in
            try NodeOutputValue.deleteOne(db, id: nodeOutputValueID)
        }
    }
}
