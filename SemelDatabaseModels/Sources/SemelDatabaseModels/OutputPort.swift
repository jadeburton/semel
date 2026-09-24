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

    /// Every port across the graph a report has to look at.
    ///
    /// Three of the states are here always: a port that failed, one whose node did not run
    /// because an input failed, and one whose node could not produce because an input never
    /// had a value. The last two carry no problem of their own — they are here so a report
    /// can count what one cause stopped.
    ///
    /// The fourth, a port nothing has processed, is here only for the kinds named in
    /// `sourceNodeKinds`: a node with no input ports will never run, so a port of one that
    /// has never produced never will. The same state on a node that does take inputs means
    /// only that its turn has not come, and every node in a fresh graph holds it.
    ///
    /// One scan of the ports. SQLite stops at the first true branch of an `OR`, so the node
    /// lookup — by primary key — happens only for the ports in that fourth state.
    public func selectAllForErrorReport(sourceNodeKinds: [UInt] = []) throws -> [OutputPort] {
        let carried: [OutputPort.ValueKind] = [.error, .inputInError, .inputNotProduced]
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
