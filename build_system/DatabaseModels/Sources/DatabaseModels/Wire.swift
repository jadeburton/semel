import Foundation
import GRDB

public struct Wire: Codable, Identifiable, FetchableRecord, PersistableRecord {
    public enum Columns {
        public static let fromNodeID = Column(CodingKeys.fromNodeID)
        public static let fromPortDefID = Column(CodingKeys.fromPortDefID)
        public static let toNodeID = Column(CodingKeys.toNodeID)
        public static let toPortDefID = Column(CodingKeys.toPortDefID)
    }

    public var id: ObjectID?
    public var fromNodeID: ObjectID
    public var fromPortDefID: ObjectID
    public var toNodeID: ObjectID
    public var toPortDefID: ObjectID

    public init(fromNodeID: ObjectID, fromPortDefID: ObjectID, toNodeID: ObjectID, toPortDefID: ObjectID) {
        self.fromNodeID = fromNodeID
        self.fromPortDefID = fromPortDefID
        self.toNodeID = toNodeID
        self.toPortDefID = toPortDefID
    }

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Wire", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fromNodeID", .integer).notNull()
                t.column("fromPortDefID", .integer).notNull()
                t.column("toNodeID", .integer).notNull()
                t.column("toPortDefID", .integer).notNull()
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

    public func selectWires(goingToNodeID: ObjectID, toPortDefID: ObjectID) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire
                .filter(Wire.Columns.toNodeID == goingToNodeID && Wire.Columns.toPortDefID == toPortDefID)
                .fetchAll(db)
        }
    }

    public func selectWires(comingFromNodeID: ObjectID) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID).fetchAll(db)
        }
    }

    public func selectWires(comingFromNodeID: ObjectID, fromPortDefID: ObjectID) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire
                .filter(Wire.Columns.fromNodeID == comingFromNodeID && Wire.Columns.fromPortDefID == fromPortDefID)
                .fetchAll(db)
        }
    }

    public func selectWires(comingFromNodeID: ObjectID, goingToNodeID: ObjectID) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                            Wire.Columns.toNodeID == goingToNodeID).fetchAll(db)
        }
    }

    public func selectWires(comingFromNodeID: ObjectID, fromPortDefID: ObjectID, goingToNodeID: ObjectID, toPortDefID: ObjectID) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                            Wire.Columns.fromPortDefID == fromPortDefID &&
                            Wire.Columns.toNodeID == goingToNodeID &&
                            Wire.Columns.toPortDefID == toPortDefID).fetchAll(db)
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

    public func deleteWire(wireID: ObjectID) throws -> Bool {
        try dbQueue.write { db in
            try Wire.deleteOne(db, id: wireID)
        }
    }
}
