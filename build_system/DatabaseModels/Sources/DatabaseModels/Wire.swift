import Foundation
import GRDB

public struct Wire: Codable, FetchableRecord, PersistableRecord {
    public enum Columns {
        public static let fromNodeID = Column(CodingKeys.fromNodeID)
        public static let fromSymbolID = Column(CodingKeys.fromSymbolID)
        public static let toNodeID = Column(CodingKeys.toNodeID)
        public static let toSymbolID = Column(CodingKeys.toSymbolID)
    }

    public var fromNodeID: ObjectID
    public var fromSymbolID: ObjectID
    public var toNodeID: ObjectID
    public var toSymbolID: ObjectID
    public var name: ObjectID // used by target Node to discern multiple wires going to the same input. Named by the creator of the target Node.

    public init(fromNodeID: ObjectID, fromSymbolID: ObjectID, toNodeID: ObjectID, toSymbolID: ObjectID, name: ObjectID) {
        self.fromNodeID = fromNodeID
        self.fromSymbolID = fromSymbolID
        self.toNodeID = toNodeID
        self.toSymbolID = toSymbolID
        self.name = name
    }

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Wire", options: .ifNotExists) { t in
                t.column("fromNodeID", .integer).notNull().indexed()
                t.column("fromSymbolID", .integer).notNull()
                t.column("toNodeID", .integer).notNull().indexed()
                t.column("toSymbolID", .integer).notNull()
                t.primaryKey(["fromNodeID", "fromSymbolID", "toNodeID", "toSymbolID"])
                t.column("name", .integer).notNull()
            }
        }
    }
}

public struct WireDataAccess: DataAccessType {
    public weak var databaseLayer: DatabaseLayer?

    public init(databaseLayer: DatabaseLayer) {
        self.databaseLayer = databaseLayer
    }

    public func selectAll() throws -> [Wire] {
        print("WARNING: expensive selectAllWires call")
        return try read { db in try Wire.fetchAll(db) }
    }

    public func select(goingToNodeID: ObjectID) throws -> [Wire] {
        try read { db in
            try Wire.filter(Wire.Columns.toNodeID == goingToNodeID).fetchAll(db)
        }
    }

    public func select(goingToNodeID: ObjectID, toSymbolID: ObjectID) throws -> [Wire] {
        try read { db in
            try Wire.filter(Wire.Columns.toNodeID == goingToNodeID &&
                            Wire.Columns.toSymbolID == toSymbolID).fetchAll(db)
        }
    }

    public func select(comingFromNodeID: ObjectID) throws -> [Wire] {
        try read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID).fetchAll(db)
        }
    }

    public func select(comingFromNodeID: ObjectID, fromSymbolID: ObjectID) throws -> [Wire] {
        try read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                            Wire.Columns.fromSymbolID == fromSymbolID).fetchAll(db)
        }
    }

    public func select(comingFromNodeID: ObjectID, goingToNodeID: ObjectID) throws -> [Wire] {
        try read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                            Wire.Columns.toNodeID == goingToNodeID).fetchAll(db)
        }
    }

    public func select(comingFromNodeID: ObjectID, fromSymbolID: ObjectID,
                       goingToNodeID: ObjectID, toSymbolID: ObjectID) throws -> [Wire] {
        try read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                            Wire.Columns.fromSymbolID == fromSymbolID &&
                            Wire.Columns.toNodeID == goingToNodeID &&
                            Wire.Columns.toSymbolID == toSymbolID).fetchAll(db)
        }
    }

    public func insert(_ wire: Wire) throws -> ObjectID {
        try write { db in
            try wire.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func update(_ wire: Wire) throws {
        try write { db in try wire.update(db) }
    }

    public func delete(comingFromNodeID: ObjectID, fromSymbolID: ObjectID,
                       goingToNodeID: ObjectID, toSymbolID: ObjectID) throws -> Bool {
        try write { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                            Wire.Columns.fromSymbolID == fromSymbolID &&
                            Wire.Columns.toNodeID == goingToNodeID &&
                            Wire.Columns.toSymbolID == toSymbolID).deleteAll(db) > 0
        }
    }
}
