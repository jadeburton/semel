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

    /// A test observable: how many wire rows have been read out of the database in this
    /// process. Scale tests state the cost of a wiring in rows rather than in seconds, the
    /// way `Folder.manifestRebuildCount` states the cost of a push in rebuilds — a count
    /// separates a lookup from a scan by the size of the graph, where a stopwatch has to be
    /// given a band wide enough to survive a loaded machine.
    ///
    /// Rows handed back, which is what a caller pays to walk. It is not what SQLite touched
    /// answering the query: a lookup the planner has no index for reads the table and
    /// returns one row, and it takes `EXPLAIN QUERY PLAN` to tell those apart.
    public static var rowsRead = 0

    /// Fetches rows and counts them into `rowsRead`. Every read of the table that can hand
    /// back more than one row goes through here.
    private func read(countingRows fetch: (Database) throws -> [Wire]) throws -> [Wire] {
        let rows = try read(fetch)
        Self.rowsRead += rows.count
        return rows
    }

    public func selectAll() throws -> [Wire] {
        Debug.warn("expensive selectAllWires call")
        return try read(countingRows: { db in try Wire.fetchAll(db) })
    }

    public func select(goingToNodeID: ObjectID) throws -> [Wire] {
        try read(countingRows: { db in
            try Wire.filter(Wire.Columns.toNodeID == goingToNodeID).fetchAll(db)
        })
    }

    public func select(goingToNodeID: ObjectID, toSymbolID: ObjectID) throws -> [Wire] {
        try read(countingRows: { db in
            try Wire.filter(Wire.Columns.toNodeID == goingToNodeID &&
                            Wire.Columns.toSymbolID == toSymbolID).fetchAll(db)
        })
    }

    public func select(comingFromNodeID: ObjectID) throws -> [Wire] {
        try read(countingRows: { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID).fetchAll(db)
        })
    }

    public func select(comingFromNodeID: ObjectID, fromSymbolID: ObjectID) throws -> [Wire] {
        try read(countingRows: { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                            Wire.Columns.fromSymbolID == fromSymbolID).fetchAll(db)
        })
    }

    /// The one wire with this exact identity, or `nil`. A port pair holds as many wires as
    /// the consumer demands names for, so the name is what selects a single row.
    public func select(comingFromNodeID: ObjectID,
                       fromSymbolID: ObjectID,
                       goingToNodeID: ObjectID,
                       toSymbolID: ObjectID,
                       name: ObjectID) throws -> Wire? {
        let wire = try read { db in
            try Wire.filter(Wire.Columns.fromNodeID == comingFromNodeID &&
                            Wire.Columns.fromSymbolID == fromSymbolID &&
                            Wire.Columns.toNodeID == goingToNodeID &&
                            Wire.Columns.toSymbolID == toSymbolID &&
                            Wire.Columns.name == name).fetchOne(db)
        }
        Self.rowsRead += wire == nil ? 0 : 1
        return wire
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
