// Node model moved into SemelDatabaseModels package

import GRDB

public struct Node: Identifiable, FetchableRecord, PersistableRecord {
    public enum Columns {
        public static let kind = Column("kind")
        public static let name = Column("name")
        public static let parentNodeID = Column("parentNodeID")
        public static let scheduled = Column("scheduled")
        public static let searchKey = Column("searchKey")
        public static let encodedProperties = Column("encodedProperties")
        public static let pendingDeletion = Column("pendingDeletion")
    }

    public var id: ObjectID?
    public var parentNodeID: ObjectID?
    public var kind: UInt
    public var name: String?
    public var properties: [String: String]
    public var scheduled: Bool
    public var searchKey: String?
    /// Set when a node loses its last output-wire consumer. Actual deletion is
    /// deferred to idle time so no structural graph mutations occur during processing.
    public var pendingDeletion: Bool

    /// The node's id, or an error if it has not been inserted yet.
    ///
    /// `id` is optional only because a Node exists briefly in memory before its row is
    /// written.  Every operation that needs an id needs a *persisted* node, so asking
    /// for one that isn't there is an integrity error to be reported — not a reason to
    /// abort the process, which is what the force unwraps this replaces used to do.
    public func requireID() throws -> ObjectID {
        guard let id else { throw NodeIdentityError.nodeNotPersisted(kind: kind, name: name) }
        return id
    }

    public init(id: ObjectID? = nil,
                parentNodeID: ObjectID? = nil,
                kind: UInt,
                name: String? = nil,
                properties: [String: String] = [:],
                scheduled: Bool = false,
                searchKey: String? = nil,
                pendingDeletion: Bool = false) {
        self.id = id
        self.parentNodeID = parentNodeID
        self.kind = kind
        self.name = name
        self.properties = properties
        self.scheduled = scheduled
        self.searchKey = searchKey
        self.pendingDeletion = pendingDeletion
    }

    // MARK: - Serialisation helpers (key=value\n format, stored in "encodedProperties" column)

    static func encodeProperties(_ dict: [String: String]) -> String? {
        guard !dict.isEmpty else { return nil }
        return dict.sorted { $0.key < $1.key }
                   .map { "\($0.key)=\($0.value)" }
                   .joined(separator: "\n")
    }

    private static func decodeProperties(_ string: String?) -> [String: String] {
        guard let string, !string.isEmpty else {
            return [:]
        }
        var result: [String: String] = [:]
        for line in string.split(separator: "\n", omittingEmptySubsequences: true) {
            if let eq = line.firstIndex(of: "=") {
                let key   = String(line[line.startIndex ..< eq])
                let value = String(line[line.index(after: eq)...])
                result[key] = value
            }
        }
        return result
    }

    // MARK: - FetchableRecord

    public init(row: Row) throws {
        id = row["id"]
        parentNodeID = row["parentNodeID"]
        kind = row["kind"]
        name = row["name"]
        scheduled = row["scheduled"] ?? false
        searchKey = row["searchKey"]
        properties = Self.decodeProperties(row["encodedProperties"])
        pendingDeletion = row["pendingDeletion"] ?? false
    }

    // MARK: - PersistableRecord

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["parentNodeID"] = parentNodeID
        container["kind"] = kind
        container["name"] = name
        container["encodedProperties"] = Self.encodeProperties(properties)
        container["scheduled"] = scheduled
        container["searchKey"] = searchKey
        container["pendingDeletion"] = pendingDeletion
    }

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Node", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("parentNodeID", .integer).indexed()
                t.column("kind", .integer).notNull().indexed()
                t.column("name", .text)
                t.column("encodedProperties", .text)
                t.column("scheduled", .integer).indexed().notNull()
                t.column("searchKey", .text).unique()
                t.column("pendingDeletion", .integer).notNull().defaults(to: false)
            }
        }
    }
}

/// A child node reduced to what a folder manifest needs. See `selectChildSummaries`.
public struct NodeChildSummary {
    public let id: ObjectID
    public let kind: UInt
    public let name: String?

    public init(id: ObjectID, kind: UInt, name: String?) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

public struct NodeDataAccess: DataAccessType {
    public weak var databaseLayer: DatabaseLayer?

    public init(databaseLayer: DatabaseLayer) {
        self.databaseLayer = databaseLayer
    }

    public func selectAllScheduled(limit: Int) throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.scheduled == true).fetchAll(db)
        }
    }

    public func selectAllPendingDeletion() throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.pendingDeletion == true).fetchAll(db)
        }
    }

    public func updatePendingDeletion(nodeID: ObjectID, pendingDeletion: Bool) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE Node SET pendingDeletion = ? WHERE id = ?",
                arguments: [pendingDeletion, nodeID]
            )
        }
    }

    public func selectChildSummaries(parentNodeID: ObjectID) throws -> [NodeChildSummary] {
        try read { db in
            try Row.fetchAll(db,
                             sql: "SELECT id, kind, name FROM Node WHERE parentNodeID = ?",
                             arguments: [parentNodeID])
                .map { NodeChildSummary(id: $0["id"], kind: $0["kind"], name: $0["name"]) }
        }
    }

    /// The value kind of one port, for every child of `parentNodeID`.
    ///
    /// Joins rather than binding the children's ids as an `IN` list: a folder with 200
    /// children meant 200 bound parameters per rebuild, which cost more than the query.
    public func selectChildPortKinds(parentNodeID: ObjectID,
                                     nameSymbolID: ObjectID) throws -> [ObjectID: OutputPort.ValueKind] {
        try read { db in
            var result: [ObjectID: OutputPort.ValueKind] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.nodeID AS nodeID, p.valueKind AS valueKind
                FROM OutputPort p
                JOIN Node n ON n.id = p.nodeID
                WHERE n.parentNodeID = ? AND p.nameSymbolID = ?
                """, arguments: [parentNodeID, nameSymbolID])
            for row in rows {
                let raw: UInt8 = row["valueKind"]
                result[row["nodeID"]] = OutputPort.ValueKind(rawValue: raw)
            }
            return result
        }
    }

    public func selectAll() throws -> [Node] {
        print("WARNING: expensive selectAllNodes call")
        return try read { db in try Node.fetchAll(db) }
    }

    public func select(nodeID: ObjectID) throws -> Node {
        guard let node = (try read { db in try Node.fetchOne(db, id: nodeID) }) else {
            throw DatabaseLayer.DatabaseError.nodeNotFound
        }
        return node
    }

    public func select(parentNodeID: ObjectID) throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.parentNodeID == parentNodeID).fetchAll(db)
        }
    }

    public func select(named name: String, parentNodeID: ObjectID?) throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.name == name &&
                            Node.Columns.parentNodeID == parentNodeID).fetchAll(db)
        }
    }

    public func select(searchKey: String) throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.searchKey == searchKey).fetchAll(db)
        }
    }

    public func select(kind: UInt, named name: String, parentNodeID: ObjectID?) throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.kind == kind &&
                            Node.Columns.name == name &&
                            Node.Columns.parentNodeID == parentNodeID).fetchAll(db)
        }
    }

    /// Every node of one kind, unqualified by name or parent.
    ///
    /// `kind` is indexed, so unlike `selectAll()` this does not scan the whole table —
    /// safe to call for a common kind as well as a rare one.
    public func select(kind: UInt) throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.kind == kind).fetchAll(db)
        }
    }

    public func insert(_ node: Node) throws -> ObjectID {
        try write { db in
            try node.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func insertOrUpdate(_ node: Node) throws {
        try write { db in try node.save(db) }
    }

    /// Updates only the `scheduled` column for the given node.
    /// Use this instead of `update(_:)` whenever changing the scheduled flag,
    /// so that concurrent tasks cannot accidentally overwrite each other's
    /// scheduling decisions by saving a stale full-node snapshot.
    public func updateScheduled(nodeID: ObjectID, scheduled: Bool) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE Node SET scheduled = ? WHERE id = ?",
                arguments: [scheduled, nodeID]
            )
        }
    }

    /// Updates all columns of the node **except** `scheduled`.
    /// Never use this to change the scheduled flag — use `updateScheduled(nodeID:scheduled:)` instead.
    public func update(_ node: Node) throws {
        try write { db in
            try db.execute(
                sql: """
                     UPDATE Node
                        SET parentNodeID      = ?,
                            kind              = ?,
                            name              = ?,
                            encodedProperties = ?,
                            searchKey         = ?
                      WHERE id = ?
                     """,
                arguments: [
                    node.parentNodeID,
                    node.kind,
                    node.name,
                    Node.encodeProperties(node.properties),
                    node.searchKey,
                    node.id
                ]
            )
        }
    }

    public func delete(nodeID: ObjectID) throws -> Bool {
        try write { db in
            let result = try Node.deleteOne(db, id: nodeID)
            try OutputPort.filter(OutputPort.Columns.nodeID == nodeID).deleteAll(db)
            return result
        }
    }
}

extension Node: CustomStringConvertible {
    public var description: String {
        "Node \(id ?? -1): kind \(kind), name=\(name ?? "nil"), scheduled=\(scheduled)"
    }
}

public enum NodeIdentityError: Error, CustomStringConvertible {
    /// An operation needed a persisted node's id, but the node has no row yet.
    case nodeNotPersisted(kind: UInt, name: String?)

    public var description: String {
        switch self {
        case .nodeNotPersisted(let kind, let name):
            return "node of kind \(kind)\(name.map { " named '\($0)'" } ?? "") has not been saved, so it has no id"
        }
    }
}
