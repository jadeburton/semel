import Foundation
import GRDB

// A Port is a live instance of an input or output of a Node.
// Each Node may have a number of Ports associated with it, and these can be added or deleted at any time.
public struct Port: Codable, FetchableRecord, PersistableRecord, Equatable {
    public enum Columns {
        public static let nodeID = Column(CodingKeys.nodeID)
        public static let portNameID = Column(CodingKeys.portNameID)
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
    public var portNameID: ObjectID
    public var valueKind: ValueKind
    public var dataObjectHash: DataObjectHash?

    public init(nodeID: ObjectID, portNameID: ObjectID, valueKind: ValueKind, dataObjectHash: DataObjectHash?) {
        self.nodeID = nodeID
        self.portNameID = portNameID
        self.valueKind = valueKind
        self.dataObjectHash = dataObjectHash
    }

    // Port uses a natural key instead of the usual "id" surrogate key.
    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Port", options: .ifNotExists) { t in
                t.column("nodeID", .integer).notNull().indexed()
                t.column("portNameID", .integer).notNull().indexed()
                t.column("valueKind", .integer).notNull()
                t.column("dataObjectHash", .text) // nullable
                t.primaryKey(["nodeID", "portNameID"])
            }
        }
    }
}

extension DatabaseLayer {

    public func selectAllPorts(nodeID: ObjectID) throws -> [Port] {
        try dbQueue.read { db in
            try Port.filter(Port.Columns.nodeID == nodeID).fetchAll(db)
        }
    }

    public func selectPort(nodeID: ObjectID, portNameID: ObjectID) throws -> Port? {
        try dbQueue.read { db in
            try Port.filter(Port.Columns.nodeID == nodeID &&
                            Port.Columns.portNameID == portNameID).fetchOne(db)
        }
    }

    public func insertOrUpdatePort(_ port: Port) throws {
        try dbQueue.write { db in
            try port.save(db)
        }
    }

    public func deletePort(nodeID: ObjectID, portNameID: ObjectID) throws -> Bool {
        try dbQueue.write { db in
            try Port
                .filter(Port.Columns.nodeID == nodeID &&
                        Port.Columns.portNameID == portNameID)
                .deleteAll(db) > 0
        }
    }

    public func deletePorts(nodeID: ObjectID) throws -> Int {
        try dbQueue.write { db in
            try Port
                .filter(Port.Columns.nodeID == nodeID)
                .deleteAll(db)
        }
    }
}

public extension Port {
    func description() -> String {
        "Port: nodeID=\(nodeID), portNameID=\(portNameID), valueKind=\(valueKind), dataObjectHash=\(dataObjectHash ?? "")"
    }
}
