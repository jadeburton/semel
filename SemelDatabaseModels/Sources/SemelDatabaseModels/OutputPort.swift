import Foundation
import GRDB

public struct OutputPort: Codable, FetchableRecord, PersistableRecord, Equatable {
    public enum Columns {
        public static let nodeID = Column(CodingKeys.nodeID)
        public static let nameSymbolID = Column(CodingKeys.nameSymbolID)
        public static let valueKind = Column(CodingKeys.valueKind)
        public static let dataObjectHash = Column(CodingKeys.dataObjectHash)
    }

    /// What a port is carrying. The raw values are written into every graph, so a new one
    /// takes a number of its own and a graph holding the old meaning of a number is refused
    /// by the version marker rather than read with this table.
    public enum ValueKind: UInt8, Codable {
        case value = 1
        case pending = 2
        case error = 5
        /// Created and not yet processed.
        case initializing = 6
        /// Did not run, because an input is in error.
        case inputInError = 7
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

public struct OutputPortDataAccess: DataAccessType {
    public weak var databaseLayer: DatabaseLayer?

    public init(databaseLayer: DatabaseLayer) {
        self.databaseLayer = databaseLayer
    }

    public func selectAll(nodeID: ObjectID) throws -> [OutputPort] {
        try read { db in
            try OutputPort.filter(OutputPort.Columns.nodeID == nodeID).fetchAll(db)
        }
    }

    public func selectAllCount() throws -> Int {
        try read { db in
            try OutputPort.fetchAll(db).count
        }
    }

    public func select(nodeID: ObjectID, nameSymbolID: ObjectID) throws -> OutputPort? {
        try read { db in
            try OutputPort.filter(OutputPort.Columns.nodeID == nodeID &&
                                  OutputPort.Columns.nameSymbolID == nameSymbolID).fetchOne(db)
        }
    }

    public func insertOrUpdate(_ port: OutputPort) throws {
        try write { db in try port.save(db) }
    }

    public func delete(nodeID: ObjectID, nameSymbolID: ObjectID) throws -> Bool {
        try write { db in
            try OutputPort.filter(OutputPort.Columns.nodeID == nodeID &&
                                  OutputPort.Columns.nameSymbolID == nameSymbolID).deleteAll(db) > 0
        }
    }

    public func deleteAll(nodeID: ObjectID) throws -> Int {
        try write { db in
            try OutputPort.filter(OutputPort.Columns.nodeID == nodeID).deleteAll(db)
        }
    }

    /// Every port across the graph that has no value because something failed: this node,
    /// or something upstream of it. A port carrying an input's failure is here so that a
    /// report can count what one failure stopped; a port that has simply not been processed
    /// is not, because nothing has failed.
    public func selectAllErrors() throws -> [OutputPort] {
        let failed = [OutputPort.ValueKind.error.rawValue, OutputPort.ValueKind.inputInError.rawValue]
        return try read { db in
            try OutputPort.filter(failed.contains(OutputPort.Columns.valueKind)).fetchAll(db)
        }
    }
}

extension OutputPort: CustomStringConvertible {
    public var description: String {
        "OutputPort: nodeID=\(nodeID), name=\(nameSymbolID.resolveSymbol()), valueKind=\(valueKind), dataObjectHash=\(dataObjectHash ?? "")"
    }
}
