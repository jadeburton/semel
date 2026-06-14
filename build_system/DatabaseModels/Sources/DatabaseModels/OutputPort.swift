import Foundation
import GRDB

public struct OutputPort: Codable, FetchableRecord, PersistableRecord, Equatable {
    public enum Columns {
        public static let nodeID = Column(CodingKeys.nodeID)
        public static let nameSymbolID = Column(CodingKeys.nameSymbolID)
        public static let valueKind = Column(CodingKeys.valueKind)
        public static let dataObjectHash = Column(CodingKeys.dataObjectHash)
    }

    public enum ValueKind: UInt8, Codable {
        case value = 1
        case pending = 2
        case error = 5
    }

    public var nodeID: ObjectID
    public var nameSymbolID: ObjectID
    public var valueKind: ValueKind
    public var dataObjectHash: DataObjectHash?

    public init(nodeID: ObjectID, nameSymbolID: ObjectID, valueKind: ValueKind, dataObjectHash: DataObjectHash?) {
        self.nodeID = nodeID
        self.nameSymbolID = nameSymbolID
        self.valueKind = valueKind
        self.dataObjectHash = dataObjectHash
    }

    // Port uses a natural key instead of the usual "id" surrogate key.
    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "OutputPort", options: .ifNotExists) { t in
                t.column("nodeID", .integer).notNull().indexed()
                t.column("nameSymbolID", .integer).notNull().indexed()
                t.column("valueKind", .integer).notNull()
                t.column("dataObjectHash", .text) // nullable
                t.primaryKey(["nodeID", "nameSymbolID"])
            }
        }
    }
}

extension DatabaseLayer {

    public func selectAllOutputPorts(nodeID: ObjectID) throws -> [OutputPort] {
        try dbQueue.read { db in
            try OutputPort.filter(OutputPort.Columns.nodeID == nodeID).fetchAll(db)
        }
    }

    public func selectOutputPort(nodeID: ObjectID, nameSymbolID: ObjectID) throws -> OutputPort? {
        try dbQueue.read { db in
            try OutputPort.filter(OutputPort.Columns.nodeID == nodeID &&
                                  OutputPort.Columns.nameSymbolID == nameSymbolID).fetchOne(db)
        }
    }

    public func insertOrUpdateOutputPort(_ port: OutputPort) throws {
        try dbQueue.write { db in
            try port.save(db)
        }
    }

    public func deleteOutputPort(nodeID: ObjectID, nameSymbolID: ObjectID) throws -> Bool {
        try dbQueue.write { db in
            try OutputPort
                .filter(OutputPort.Columns.nodeID == nodeID &&
                        OutputPort.Columns.nameSymbolID == nameSymbolID)
                .deleteAll(db) > 0
        }
    }

    public func deleteOutputPorts(nodeID: ObjectID) throws -> Int {
        try dbQueue.write { db in
            try OutputPort
                .filter(OutputPort.Columns.nodeID == nodeID)
                .deleteAll(db)
        }
    }
}

public extension OutputPort {
    func description() -> String {
        "OutputPort: nodeID=\(nodeID), name=\(nameSymbolID.resolveSymbol()), valueKind=\(valueKind), dataObjectHash=\(dataObjectHash ?? "")"
    }
}
