import Foundation
import GRDB

public struct NodeOutputValue: Codable, FetchableRecord, PersistableRecord {
    public enum Columns {
        public static let nodeID = Column(CodingKeys.nodeID)
        public static let port = Column(CodingKeys.port)
        public static let dataObjectHash = Column(CodingKeys.dataObjectHash)
    }

    public var nodeID: ObjectID
    public var port: UInt8
    public var dataObjectHash: DataObjectHash?

    public init(nodeID: ObjectID, port: UInt8, dataObjectHash: DataObjectHash?) {
        self.nodeID = nodeID
        self.port = port
        self.dataObjectHash = dataObjectHash
    }

    // NodeOutputValue uses a natural key instead of the usual "id" surrogate key.
    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "NodeOutputValue", options: .ifNotExists) { t in
                t.column("nodeID", .integer).notNull()
                t.column("port", .integer).notNull()
                t.column("dataObjectHash", .text) // nullable
                t.primaryKey(["nodeID", "port"])
            }
        }
    }
}

extension DatabaseLayer {
    public func selectAllNodeOutputValues() throws -> [NodeOutputValue] {
        try dbQueue.read { db in
            try NodeOutputValue.fetchAll(db)
        }
    }

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

    public func deleteNodeOutputValue(nodeID: ObjectID, port: UInt8) throws -> Bool {
        try dbQueue.write { db in
            try NodeOutputValue
                .filter(NodeOutputValue.Columns.nodeID == nodeID && NodeOutputValue.Columns.port == port)
                .deleteAll(db) > 0
        }
    }
}

public extension NodeOutputValue {
    func description() -> String {
        "NodeOutputValue: nodeID=\(nodeID), port=\(port), dataObjectHash=\(String(describing: dataObjectHash))"
    }
}
