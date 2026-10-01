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

            // A wire's name is unique per input port, and a port takes a fan of wires as
            // wide as the graph demands, so asking whether a name is taken has to be a
            // lookup rather than a walk of the fan. The primary key leads with the source
            // and cannot serve that question; the index on `toNodeID` alone answers it with
            // every wire arriving at the node. These are the three columns the question is
            // asked in (B-106).
            //
            // Outside the table's own `ifNotExists`, and so created whether the table was
            // just made or was already there. An index changes what a lookup costs and not
            // what a row means, so a database holding wires without it is a database to
            // index rather than one to refuse: `createTables` runs on every open and the
            // schema fingerprint is taken after it, so such a file gains the index and then
            // presents the fingerprint a fresh one does.
            //
            // Not unique: the key that says a name belongs to one source is enforced where
            // the rule lives, in `connectWire`, which refuses the second source with a
            // sentence. A constraint here would answer it with an SQLite error instead.
            try db.create(indexOn: "Wire",
                          columns: ["toNodeID", "toSymbolID", "name"],
                          options: .ifNotExists)
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
    /// Rows returned, not statements run: a guard that reads a whole fan to answer one
    /// question is one statement and as many rows as the fan holds, and it is the rows that
    /// say so. Nor is it what SQLite touched answering the query — a lookup the planner has
    /// no index for reads the table and returns one row, and it takes `EXPLAIN QUERY PLAN`
    /// to tell those apart. Named for what it counts, so a counter of statements can sit
    /// beside it under a name of its own.
    public static let rowsRead = SharedCounter()

    /// Fetches rows, counting the select into `selectCount` and the rows into `rowsRead`.
    /// Every read of the table that can hand back more than one row goes through here.
    private func read(countingRows fetch: (Database) throws -> [Wire]) throws -> [Wire] {
        let rows = try counted { try read(fetch) }
        Self.rowsRead.add(rows.count)
        return rows
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
    static let selectCount = SharedCounter()

    /// Counts one query against `selectCount` and runs it, so that a select added here
    /// cannot quietly escape the measurement.
    private func counted<T>(_ query: () throws -> T) rethrows -> T {
        Self.selectCount.increment()
        return try query()
    }

    public func selectAll() throws -> [Wire] {
        Debug.warn("expensive selectAllWires call")
        return try read(countingRows: { db in try Wire.fetchAll(db) })
    }

    public func select(goingToNodeID: ObjectID) throws -> [Wire] {
        try read(countingRows: { db in
            try db.cachedRecords("SELECT * FROM Wire WHERE toNodeID = ?", arguments: [goingToNodeID])
        })
    }

    public func select(goingToNodeID: ObjectID, toSymbolID: ObjectID) throws -> [Wire] {
        try read(countingRows: { db in
            try db.cachedRecords("SELECT * FROM Wire WHERE toNodeID = ? AND toSymbolID = ?",
                                 arguments: [goingToNodeID, toSymbolID])
        })
    }

    /// Every wire arriving at `(goingToNodeID, toSymbolID)` under `name` — an indexed
    /// lookup, so it costs the same whatever else arrives at that port. Rows rather than one
    /// row: the schema permits two sources to reach a port under one name, `connectWire` is
    /// what refuses it, and what a graph damaged past that rule holds is the caller's to
    /// judge rather than this method's to hide.
    public func select(goingToNodeID: ObjectID, toSymbolID: ObjectID, name: ObjectID) throws -> [Wire] {
        try read(countingRows: { db in
            try db.cachedRecords("SELECT * FROM Wire WHERE toNodeID = ? AND toSymbolID = ? AND name = ?",
                                 arguments: [goingToNodeID, toSymbolID, name])
        })
    }

    public func select(comingFromNodeID: ObjectID) throws -> [Wire] {
        try read(countingRows: { db in
            try db.cachedRecords("SELECT * FROM Wire WHERE fromNodeID = ?", arguments: [comingFromNodeID])
        })
    }

    public func select(comingFromNodeID: ObjectID, fromSymbolID: ObjectID) throws -> [Wire] {
        try read(countingRows: { db in
            try db.cachedRecords("SELECT * FROM Wire WHERE fromNodeID = ? AND fromSymbolID = ?",
                                 arguments: [comingFromNodeID, fromSymbolID])
        })
    }

    /// The one wire with this exact identity, or `nil`. A port pair holds as many wires as
    /// the consumer demands names for, so the name is what selects a single row.
    public func select(comingFromNodeID: ObjectID,
                       fromSymbolID: ObjectID,
                       goingToNodeID: ObjectID,
                       toSymbolID: ObjectID,
                       name: ObjectID) throws -> Wire? {
        let wire: Wire? = try counted {
            try read { db in
                try db.cachedRecord("SELECT * FROM Wire WHERE \(Self.wholeKey)",
                                    arguments: [comingFromNodeID, fromSymbolID, goingToNodeID, toSymbolID, name])
            }
        }
        Self.rowsRead.add(wire == nil ? 0 : 1)
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
            try db.cachedExecute("DELETE FROM Wire WHERE \(Self.wholeKey)",
                                 arguments: [comingFromNodeID, fromSymbolID, goingToNodeID, toSymbolID, name])
            return db.changesCount > 0
        }
    }

    /// One wire by its whole identity: the primary key, in its order.
    private static let wholeKey = "fromNodeID = ? AND fromSymbolID = ? AND toNodeID = ? AND toSymbolID = ? AND name = ?"

    public func delete(wire: Wire) throws -> Bool {
        try delete(comingFromNodeID: wire.fromNodeID,
                   fromSymbolID:     wire.fromSymbolID,
                   goingToNodeID:    wire.toNodeID,
                   toSymbolID:       wire.toSymbolID,
                   name:             wire.name)
    }
}
