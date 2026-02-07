import Foundation
import GRDB

public struct Wire: Codable, Identifiable, FetchableRecord, PersistableRecord {
    public enum Columns {
        public static let fromNodeID = Column(CodingKeys.fromNodeID)
        public static let fromPort = Column(CodingKeys.fromPort)
        public static let toNodeID = Column(CodingKeys.toNodeID)
        public static let toPort = Column(CodingKeys.toPort)
    }

    public var id: ObjectID?
    public var fromNodeID: ObjectID
    public var fromPort: UInt8
    public var toNodeID: ObjectID
    public var toPort: UInt8

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Wire", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fromNodeID", .integer).notNull()
                t.column("fromPort", .integer).notNull()
                t.column("toNodeID", .integer).notNull()
                t.column("toPort", .integer).notNull()
            }
        }
    }
}

extension DatabaseLayer {
    public static func selectWires(goingToNodeID: ObjectID, dbQueue: DatabaseQueue) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire.filter(Wire.Columns.toNodeID == goingToNodeID).fetchAll(db)
        }
    }

    public static func selectWires(goingToNodeID: ObjectID, toPort: UInt8, dbQueue: DatabaseQueue) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire
                .filter(Wire.Columns.toNodeID == goingToNodeID && Wire.Columns.toPort == toPort)
                .fetchAll(db)
        }
    }

    public static func selectWires(comingFromNodeID: ObjectID, dbQueue: DatabaseQueue) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID).fetchAll(db)
        }
    }

    public static func selectWires(comingFromNodeID: ObjectID, fromPort: UInt8, dbQueue: DatabaseQueue) throws -> [Wire] {
        try dbQueue.read { db in
            try Wire
                .filter(Wire.Columns.fromNodeID == comingFromNodeID && Wire.Columns.fromPort == fromPort)
                .fetchAll(db)
        }
    }

    public static func insertWire(_ wire: Wire, dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try wire.insert(db)
        }
    }

    public static func updateWire(_ wire: Wire, dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try wire.update(db)
        }
    }

    public static func deleteWire(wireID: ObjectID, dbQueue: DatabaseQueue) throws -> Bool {
        try dbQueue.write { db in
            try Wire.deleteOne(db, id: wireID)
        }
    }
}
