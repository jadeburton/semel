import Foundation
import GRDB

public struct Wire: Codable, FetchableRecord, PersistableRecord {
    public enum Columns {
        public static let fromNodeID = Column(CodingKeys.fromNodeID)
        public static let fromSymbolID = Column(CodingKeys.fromSymbolID)
        public static let toNodeID = Column(CodingKeys.toNodeID)
        public static let toSymbolID = Column(CodingKeys.toSymbolID)
        public static let name = Column(CodingKeys.name)
    }

    public var fromNodeID: ObjectID
    public var fromSymbolID: ObjectID
    public var toNodeID: ObjectID
    public var toSymbolID: ObjectID
    /// Used by the target node to discern multiple wires going to the same input. Named by
    /// the creator of the target node, and part of the wire's identity: two consumers of one
    /// output port may each demand it under a name of their own.
    public var name: ObjectID

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
                t.column("name", .integer).notNull()
                t.primaryKey(["fromNodeID", "fromSymbolID", "toNodeID", "toSymbolID", "name"])
            }
        }
    }
}

public struct WireDataAccess: DataAccessType {
    public weak var databaseLayer: DatabaseLayer?

    public init(databaseLayer: DatabaseLayer) {
        self.databaseLayer = databaseLayer
    }

    /// How many wire selects this process has issued.
    ///
    /// A test observable, of a piece with `Folder.manifestRebuildCount` and
    /// `BuildEngine.loopSignalsSent`: a cost whose shape is a count of round trips, which
    /// a stopwatch cannot pin — a timing assertion needs a band wide enough to survive a
    /// loaded machine, and such a band stops telling linear growth from quadratic long
    /// before the defect stops mattering. Every `select` below counts one, whatever it
    /// returns. Not read by the engine; `CascadeReportScaleTests` reads it around the
    /// error report's upstream walk.
    static var selectCount = 0

    /// Counts one query against `selectCount` and runs it, so that a select added here
    /// cannot quietly escape the measurement.
    private func counted<T>(_ query: () throws -> T) rethrows -> T {
        Self.selectCount += 1
        return try query()
    }

    public func selectAll() throws -> [Wire] {
        Debug.warn("expensive selectAllWires call")
        return try counted { try read { db in try Wire.fetchAll(db) } }
    }

    public func select(goingToNodeID: ObjectID) throws -> [Wire] {
        try counted {
            try read { db in
                try Wire.filter(Wire.Columns.toNodeID == goingToNodeID).fetchAll(db)
            }
        }
    }

    public func select(goingToNodeID: ObjectID, toSymbolID: ObjectID) throws -> [Wire] {
        try counted {
            try read { db in
                try Wire.filter(Wire.Columns.toNodeID == goingToNodeID &&
                                Wire.Columns.toSymbolID == toSymbolID).fetchAll(db)
            }
        }
    }

    public func select(comingFromNodeID: ObjectID) throws -> [Wire] {
        try counted {
            try read { db in
                try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID).fetchAll(db)
            }
        }
    }

    public func select(comingFromNodeID: ObjectID, fromSymbolID: ObjectID) throws -> [Wire] {
        try counted {
            try read { db in
                try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                                Wire.Columns.fromSymbolID == fromSymbolID).fetchAll(db)
            }
        }
    }

    /// The one wire with this exact identity, or `nil`. A port pair holds as many wires as
    /// the consumer demands names for, so the name is what selects a single row.
    public func select(comingFromNodeID: ObjectID,
                       fromSymbolID: ObjectID,
                       goingToNodeID: ObjectID,
                       toSymbolID: ObjectID,
                       name: ObjectID) throws -> Wire? {
        try counted {
            try read { db in
                try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                                Wire.Columns.fromSymbolID == fromSymbolID &&
                                Wire.Columns.toNodeID == goingToNodeID &&
                                Wire.Columns.toSymbolID == toSymbolID &&
                                Wire.Columns.name == name).fetchOne(db)
            }
        }
    }

    public func insert(_ wire: Wire) throws -> ObjectID {
        try write { db in
            try wire.insert(db)
            return db.lastInsertedRowID
        }
    }

    /// Deletes the one wire with this identity. Every other wire between the same pair of
    /// ports stays: it belongs to a different consumer's demand.
    public func delete(comingFromNodeID: ObjectID,
                       fromSymbolID: ObjectID,
                       goingToNodeID: ObjectID,
                       toSymbolID: ObjectID,
                       name: ObjectID) throws -> Bool {
        try write { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                            Wire.Columns.fromSymbolID == fromSymbolID &&
                            Wire.Columns.toNodeID == goingToNodeID &&
                            Wire.Columns.toSymbolID == toSymbolID &&
                            Wire.Columns.name == name).deleteAll(db) > 0
        }
    }

    public func delete(wire: Wire) throws -> Bool {
        try delete(comingFromNodeID: wire.fromNodeID,
                   fromSymbolID:     wire.fromSymbolID,
                   goingToNodeID:    wire.toNodeID,
                   toSymbolID:       wire.toSymbolID,
                   name:             wire.name)
    }
}
