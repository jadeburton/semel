import Foundation
import GRDB

public struct NodeOutputValue: Codable, FetchableRecord, PersistableRecord, Equatable {
    public enum Columns {
        public static let nodeID = Column(CodingKeys.nodeID)
        public static let port = Column(CodingKeys.port)
        public static let kind = Column(CodingKeys.kind)
        public static let dataObjectHash = Column(CodingKeys.dataObjectHash)
        public static let metadata = Column(CodingKeys.metadata)
        public static let errorMessage = Column(CodingKeys.errorMessage)
    }

    public enum ValueKind: UInt8, Codable {
        case value = 1
        case pending = 2
        case error = 5
    }

    public var nodeID: ObjectID
    public var port: UInt8
    public var kind: ValueKind
    public var dataObjectHash: DataObjectHash?
    public var metadata: String?
    public var errorMessage: String?

    public init(nodeID: ObjectID, port: UInt8, kind: ValueKind, dataObjectHash: DataObjectHash?, metadata: String?, errorMessage: String?) {
        self.nodeID = nodeID
        self.port = port
        self.kind = kind
        self.dataObjectHash = dataObjectHash
        self.metadata = metadata
        self.errorMessage = errorMessage
    }

    // NodeOutputValue uses a natural key instead of the usual "id" surrogate key.
    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "NodeOutputValue", options: .ifNotExists) { t in
                t.column("nodeID", .integer).notNull().indexed()
                t.column("port", .integer).notNull()
                t.column("kind", .integer).notNull()
                t.column("dataObjectHash", .text) // nullable
                t.column("metadata", .text) // nullable
                t.column("errorMessage", .text) // nullable
                t.primaryKey(["nodeID", "port"])
            }
        }
    }
}

extension DatabaseLayer {

    public func selectAllNodeOutputValues(limit: Int) throws -> [NodeOutputValue] {
        try dbQueue.read { db in
            try NodeOutputValue
                .limit(limit)
                .order(Column("nodeID").asc)
                .fetchAll(db)
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

    public func deleteNodeOutputValues(nodeID: ObjectID) throws -> Int {
        try dbQueue.write { db in
            try NodeOutputValue
                .filter(NodeOutputValue.Columns.nodeID == nodeID)
                .deleteAll(db)
        }
    }
}

public extension NodeOutputValue {
    func description() -> String {
        "NodeOutputValue: nodeID=\(nodeID), port=\(port), dataObjectHash=\(dataObjectHash ?? "")"
    }
}
