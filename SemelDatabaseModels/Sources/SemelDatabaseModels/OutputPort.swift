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
        /// Could not produce, because an input has never been produced.
        case inputNotProduced = 8
        /// A source that was pushed and then removed.
        case deleted = 9
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

/// One wire into an input port, with what its source port holds: the row, or nil where the
/// source has no row for the port it is wired from.
public struct ArrivingValue: Equatable {
    public let wireName: ObjectID
    public let port:     OutputPort?

    public init(wireName: ObjectID, port: OutputPort?) {
        self.wireName = wireName
        self.port     = port
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

    /// Every distinct object a port refers to — a value, or an error's message — without
    /// the ports: the collector's root set, one column of hex (B-14).
    public func selectAllHashes() throws -> [DataObjectHash] {
        try read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT dataObjectHash FROM OutputPort WHERE dataObjectHash IS NOT NULL")
        }
    }

    public func selectAllCount() throws -> Int {
        try read { db in
            try OutputPort.fetchAll(db).count
        }
    }

    /// How many port selects this process has issued through `select` and
    /// `selectArriving`. A test observable, of a piece with `WireDataAccess.selectCount`:
    /// reading a node's inputs is done on every evaluation of the node, and a read that
    /// costs a select per wire arriving is a cost that follows the fan (B-124). Not read by
    /// the engine.
    public static let selectCount = SharedCounter()

    public func select(nodeID: ObjectID, nameSymbolID: ObjectID) throws -> OutputPort? {
        Self.selectCount.increment()
        return try read { db in
            try OutputPort.filter(OutputPort.Columns.nodeID == nodeID &&
                                  OutputPort.Columns.nameSymbolID == nameSymbolID).fetchOne(db)
        }
    }

    /// What arrives on every wire into one input port, in one query: each wire's name with
    /// the row of the source port it comes from, or no row where that source has never
    /// written the port.
    ///
    /// One query, not the wires and then a select per wire. A node reads every input port
    /// on every evaluation, and each select is a round trip through the serialised
    /// database — its own queue hop, savepoint and statement — so a consumer of a wide fan
    /// paid the width of the fan per evaluation: the project finder, wired to the manifest
    /// of every folder of a tree, read some seventeen hundred ports each time a builder
    /// below it wrote, and a cold build of a large app spent most of its time there (B-124).
    /// The wire rows the join hands back are counted into `WireDataAccess.rowsRead` as any
    /// read of the wire table is, so the scale tests see them.
    public func selectArriving(atNodeID toNodeID: ObjectID, toSymbolID: ObjectID) throws -> [ArrivingValue] {
        Self.selectCount.increment()
        WireDataAccess.selectCount.increment()
        let rows = try read { db in
            try Row.fetchAll(db, sql: """
                SELECT w.name AS wireName, p.nodeID, p.nameSymbolID, p.valueKind, p.dataObjectHash
                FROM Wire w
                LEFT JOIN OutputPort p ON p.nodeID = w.fromNodeID AND p.nameSymbolID = w.fromSymbolID
                WHERE w.toNodeID = ? AND w.toSymbolID = ?
                """, arguments: [toNodeID, toSymbolID])
        }
        WireDataAccess.rowsRead.add(rows.count)
        return try rows.map { row in
            let wireName: ObjectID = row["wireName"]
            // A source without a row for the port leaves the joined columns null.
            guard (row["nodeID"] as ObjectID?) != nil else {
                return ArrivingValue(wireName: wireName, port: nil)
            }
            return ArrivingValue(wireName: wireName, port: try OutputPort(row: row))
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

    /// Every port across the graph a report has to look at.
    ///
    /// Four of the states are here always: a port that failed, one carrying a source that
    /// was removed, one whose node did not run because an input failed, and one whose node
    /// could not produce because an input never had a value. The last two carry no problem
    /// of their own — they are here so a report can count what one cause stopped.
    ///
    /// The fifth, a port nothing has processed, is here only for the kinds named in
    /// `sourceNodeKinds`: a node with no input ports will never run, so a port of one that
    /// has never produced never will. The same state on a node that does take inputs means
    /// only that its turn has not come, and every node in a fresh graph holds it.
    ///
    /// One scan of the ports. The node lookup — by primary key — sits behind an `AND` whose
    /// left side is the state test, and SQLite stops at the first false branch of an `AND`,
    /// so the lookup happens only for the ports already in that fourth state.
    ///
    /// `sourceNodeKinds` takes no default: an empty list is a valid answer from a registry
    /// with no source types in it, and a caller that meant to pass one and did not would
    /// silently get a report that never names a file.
    public func selectAllForErrorReport(sourceNodeKinds: [UInt]) throws -> [OutputPort] {
        let carried: [OutputPort.ValueKind] = [.error, .deleted, .inputInError, .inputNotProduced]
        let carriedList = carried.map { _ in "?" }.joined(separator: ", ")
        var arguments   = carried.map { Int64($0.rawValue) }

        // No source kinds to ask about means no port is in that fourth state worth looking
        // at, and an empty `IN ()` is not SQL.
        var unproduced = "0"
        if !sourceNodeKinds.isEmpty {
            let kindList = sourceNodeKinds.map { _ in "?" }.joined(separator: ", ")
            unproduced = "(p.valueKind = ? AND EXISTS "
                       + "(SELECT 1 FROM Node n WHERE n.id = p.nodeID AND n.kind IN (\(kindList))))"
            arguments.append(Int64(OutputPort.ValueKind.initializing.rawValue))
            arguments.append(contentsOf: sourceNodeKinds.map(Int64.init))
        }

        return try read { db in
            try OutputPort.fetchAll(db, sql: """
                SELECT p.nodeID, p.nameSymbolID, p.valueKind, p.dataObjectHash
                FROM OutputPort p
                WHERE p.valueKind IN (\(carriedList)) OR \(unproduced)
                """, arguments: StatementArguments(arguments))
        }
    }
}

extension OutputPort: CustomStringConvertible {
    public var description: String {
        "OutputPort: nodeID=\(nodeID), name=\(nameSymbolID.resolveSymbol()), valueKind=\(valueKind), dataObjectHash=\(dataObjectHash ?? "")"
    }
}
