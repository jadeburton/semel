import Foundation
import GRDB

// A Port is a live instance of an input or output of a Node.
// Each Node may have a number of Ports associated with it, and these can be added or deleted at any time.
public struct Port: Codable, FetchableRecord, PersistableRecord, Equatable {
    public enum Columns {
        public static let nodeID = Column(CodingKeys.nodeID)
        public static let portDefID = Column(CodingKeys.portDefID)
        public static let valueKind = Column(CodingKeys.valueKind)
        public static let dataObjectHash = Column(CodingKeys.dataObjectHash)
    }

    public enum ValueKind: UInt8, Codable {
        case notApplicable = 0 // input ports do not have values
        case value = 1
        case pending = 2
        case error = 5
    }

    public var nodeID: ObjectID
    public var portDefID: ObjectID
    public var valueKind: ValueKind
    public var dataObjectHash: DataObjectHash?

    public init(nodeID: ObjectID, portDefID: ObjectID, valueKind: ValueKind, dataObjectHash: DataObjectHash?) {
        self.nodeID = nodeID
        self.portDefID = portDefID
        self.valueKind = valueKind
        self.dataObjectHash = dataObjectHash
    }

    // NodeOutputValue uses a natural key instead of the usual "id" surrogate key.
    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Port", options: .ifNotExists) { t in
                t.column("nodeID", .integer).notNull().indexed()
                t.column("portDefID", .integer).notNull().indexed()
                t.column("valueKind", .integer).notNull()
                t.column("dataObjectHash", .text) // nullable
            }
        }
    }
}

extension DatabaseLayer {

    // Select all NodeOutputValues associated with the given Node
    public func selectAllPorts(nodeID: ObjectID) throws -> [Port] {
        try dbQueue.read { db in
            try Port.filter(Port.Columns.nodeID == nodeID).fetchAll(db)
        }
    }

    public func selectPort(nodeID: ObjectID, portID: ObjectID) throws -> Port? {
        try dbQueue.read { db in
            try Port.filter(Port.Columns.nodeID == nodeID &&
                            Port.Columns.portID == portID).fetchOne(db)
        }
    }

    public func insertOrReplaceNodeOutputValue(_ nodeOutputValue: NodeOutputValue) throws {
        try dbQueue.write { db in
            try nodeOutputValue.save(db)
        }
    }

    public func deleteNodeOutputValue(nodeID: ObjectID, portID: ObjectID) throws -> Bool {
        try dbQueue.write { db in
            try NodeOutputValue
                .filter(NodeOutputValue.Columns.nodeID == nodeID &&
                        NodeOutputValue.Columns.portID == portID)
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
