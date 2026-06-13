import Foundation
import GRDB

public struct Wire: Codable, FetchableRecord, PersistableRecord {
    public enum Columns {
        public static let fromNodeID = Column(CodingKeys.fromNodeID)
        public static let fromPortNameID = Column(CodingKeys.fromPortNameID)
        public static let toNodeID = Column(CodingKeys.toNodeID)
        public static let toPortNameID = Column(CodingKeys.toPortNameID)
    }

    public var fromNodeID: ObjectID
    public var fromPortNameID: ObjectID
    public var toNodeID: ObjectID
    public var toPortNameID: ObjectID
    public var name: ObjectID // used by target Node to discern multiple wires going to the same input. Named by the creator of the target Node.

    public init(fromNodeID: ObjectID, fromPortNameID: ObjectID, toNodeID: ObjectID, toPortNameID: ObjectID, name: ObjectID) {
        self.fromNodeID = fromNodeID
        self.fromPortNameID = fromPortNameID
        self.toNodeID = toNodeID
        self.toPortNameID = toPortNameID
        self.name = name
    }

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Wire", options: .ifNotExists) { t in
                t.column("fromNodeID", .integer).notNull().indexed()
                t.column("fromPortNameID", .integer).notNull()
                t.column("toNodeID", .integer).notNull().indexed()
                t.column("toPortNameID", .integer).notNull()
                t.primaryKey(["fromNodeID", "fromPortNameID", "toNodeID", "toPortNameID"])
                t.column("name", .integer).notNull()
            }
        }
    }
}

extension DatabaseLayer {
    public func selectAllWires() throws -> [Wire] {
        try dbQueue.read { db in
            try Wire.fetchAll(db)
        }
    }

    public func selectWires(goingToNodeID: ObjectID) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire.filter(Wire.Columns.toNodeID == goingToNodeID).fetchAll(db)
        }
    }

    public func selectWires(goingToNodeID: ObjectID, toPortNameID: ObjectID) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire
                .filter(Wire.Columns.toNodeID == goingToNodeID && Wire.Columns.toPortNameID == toPortNameID)
                .fetchAll(db)
        }
    }

    public func selectWires(comingFromNodeID: ObjectID) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID).fetchAll(db)
        }
    }

    public func selectWires(comingFromNodeID: ObjectID, fromPortNameID: ObjectID) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire
                .filter(Wire.Columns.fromNodeID == comingFromNodeID && Wire.Columns.fromPortNameID == fromPortNameID)
                .fetchAll(db)
        }
    }

    public func selectWires(comingFromNodeID: ObjectID, goingToNodeID: ObjectID) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                            Wire.Columns.toNodeID == goingToNodeID).fetchAll(db)
        }
    }

    public func selectWires(comingFromNodeID: ObjectID, fromPortNameID: ObjectID, goingToNodeID: ObjectID, toPortNameID: ObjectID) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                            Wire.Columns.fromPortNameID == fromPortNameID &&
                            Wire.Columns.toNodeID == goingToNodeID &&
                            Wire.Columns.toPortNameID == toPortNameID).fetchAll(db)
        }
    }

    public func insertWire(_ wire: Wire) throws -> ObjectID {
        try dbQueue.write { db in
            try wire.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func updateWire(_ wire: Wire) throws {
        try dbQueue.write { db in
            try wire.update(db)
        }
    }

    public func deleteWire(comingFromNodeID: ObjectID, fromPortNameID: ObjectID, goingToNodeID: ObjectID, toPortNameID: ObjectID) throws -> Bool {
        #warning("TODO")
//        try dbQueue.write { db in
//            try Wire.deleteOne(db, key: K)
//        }
        return true
    }
}
