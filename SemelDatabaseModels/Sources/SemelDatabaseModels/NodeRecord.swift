// NodeRecord.swift
// SemelDatabaseModels
//
// One row of the graph: what a node is, stripped of what it does.
//
// A node has two halves. This is the persisted one — identity, properties, parentage,
// whether it is scheduled — and it knows nothing about ports, processing, or its own kind
// beyond an integer. The behaviour lives a layer up, in `Node`, which wraps one of
// these and is what the rest of the system actually works with. Splitting them is what lets
// the engine load, count and delete nodes without instantiating anything that could run.

import GRDB

public struct NodeRecord: Identifiable, FetchableRecord, PersistableRecord {

    /// Pinned rather than derived. GRDB's default turns a type name into a table name, so
    /// renaming this type would rename the table — and `Node` happened to still match the
    /// created table only because SQLite compares table names case-insensitively. The schema
    /// should not move because a Swift type did.
    public static let databaseTableName = "Node"

    public enum Columns {
        public static let kind = Column("kind")
        public static let name = Column("name")
        public static let parentNodeID = Column("parentNodeID")
        public static let scheduled = Column("scheduled")
        public static let identity = Column("identity")
        public static let encodedProperties = Column("encodedProperties")
        public static let pendingDeletion = Column("pendingDeletion")
    }

    public var id: ObjectID?
    public var parentNodeID: ObjectID?
    public var kind: UInt
    public var name: String?
    public var properties: [String: String]
    public var scheduled: Bool
    public var identity: String?
    /// Set when a node loses its last output-wire consumer. Actual deletion is
    /// deferred to idle time so no structural graph mutations occur during processing.
    public var pendingDeletion: Bool

    /// The node's id, or an error if it has not been inserted yet.
    ///
    /// `id` is optional only because a NodeRecord exists briefly in memory before its row is
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
                identity: String? = nil,
                pendingDeletion: Bool = false) {
        self.id = id
        self.parentNodeID = parentNodeID
        self.kind = kind
        self.name = name
        self.properties = properties
        self.scheduled = scheduled
        self.identity = identity
        self.pendingDeletion = pendingDeletion
    }

    // MARK: - Serialisation helpers (key=value\n format, stored in "encodedProperties" column)

    static func encodeProperties(_ dict: [String: String]) -> String? {
        guard !dict.isEmpty else {
            return nil
        }
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
        identity = row["identity"]
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
        container["identity"] = identity
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
                t.column("identity", .text).unique()
                t.column("pendingDeletion", .integer).notNull().defaults(to: false)
            }

            // The file-system tree is walked by name — a push resolves every folder on the
            // way to its file, `childNode` follows a path — and a folder can hold thousands
            // of children, so a step of the walk has to be a lookup rather than a read of
            // every sibling the index on `parentNodeID` alone would hand back (B-131).
            // Outside the table's own `ifNotExists` for the reason the wire index is: an
            // existing database gains it on open and then presents a fresh one's fingerprint.
            try db.create(indexOn: "Node",
                          columns: ["parentNodeID", "name"],
                          options: .ifNotExists)

            // A folder's subfolders without its files: what a push reads to compare a tree
            // with the disk (`selectSubtree`, B-132). Without it each step of that walk reads
            // every child's row to learn its kind — the IceCubes app tree's 8,039 files to
            // find its 1,670 folders, 0.4 s — where with it the walk is 2 ms.
            try db.create(indexOn: "Node",
                          columns: ["parentNodeID", "kind"],
                          options: .ifNotExists)
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

/// One node on a path walked by `selectPath`: how far below the starting node it stands,
/// its row, and its rows for the ports the walk was asked to bring, by port symbol. A port
/// the node holds no row for is absent.
public struct NodePathStep {
    public let depth: Int
    public let node:  NodeRecord
    public var ports: [ObjectID: OutputPort]

    public init(depth: Int, node: NodeRecord, ports: [ObjectID: OutputPort]) {
        self.depth = depth
        self.node  = node
        self.ports = ports
    }
}

/// One node of a subtree walked by `selectSubtree`: its id, its parent's, its name, how far
/// below the starting node it stands, and its rows for the ports the walk was asked to
/// bring, by port symbol.
public struct NodeSubtreeRow {
    public let id:           ObjectID
    public let parentNodeID: ObjectID?
    public let name:         String?
    public let depth:        Int
    public var ports:        [ObjectID: OutputPort]

    public init(id: ObjectID, parentNodeID: ObjectID?, name: String?, depth: Int, ports: [ObjectID: OutputPort]) {
        self.id           = id
        self.parentNodeID = parentNodeID
        self.name         = name
        self.depth        = depth
        self.ports        = ports
    }
}

public struct NodeDataAccess: DataAccessType {
    public weak var databaseLayer: DatabaseLayer?

    public init(databaseLayer: DatabaseLayer) {
        self.databaseLayer = databaseLayer
    }

    /// How many node selects this process has issued. A test observable, of a piece with
    /// `OutputPortDataAccess.selectCount` and `WireDataAccess.selectCount`: each select is a
    /// round trip through the serialised database — a queue hop, a savepoint and a
    /// statement — so a lookup made once per path component is a cost that follows the
    /// depth of the tree, and a count is what pins it (B-131). Not read by the engine.
    public static let selectCount = SharedCounter()

    /// Counts one query against `selectCount` and runs it, so that a select added here
    /// cannot quietly escape the measurement.
    private func selecting<T>(_ block: (Database) throws -> T) throws -> T {
        Self.selectCount.increment()
        return try read(block)
    }

    /// At most `limit` scheduled nodes, leaving out `excluding` — the nodes the caller is
    /// already running — in id order.
    public func selectScheduled(limit: Int, excluding: Set<ObjectID> = []) throws -> [NodeRecord] {
        try selecting { db in
            try NodeRecord
                .filter(NodeRecord.Columns.scheduled == true && !excluding.contains(Column("id")))
                .order(Column("id"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// How many nodes are scheduled: the queue ahead of a pass, which a running node has
    /// already left (B-95).
    public func countScheduled() throws -> Int {
        try selecting { db in
            try NodeRecord.filter(NodeRecord.Columns.scheduled == true).fetchCount(db)
        }
    }

    public func selectAllPendingDeletion() throws -> [NodeRecord] {
        try selecting { db in
            try NodeRecord.filter(NodeRecord.Columns.pendingDeletion == true).fetchAll(db)
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
        try selecting { db in
            try Row.fetchAll(db,
                             sql: "SELECT id, kind, name FROM Node WHERE parentNodeID = ?",
                             arguments: [parentNodeID])
                .map { NodeChildSummary(id: $0["id"], kind: $0["kind"], name: $0["name"]) }
        }
    }

    /// One port, for every child of `parentNodeID` that has it.
    ///
    /// Joins rather than binding the children's ids as an `IN` list: a folder with 200
    /// children meant 200 bound parameters per rebuild, which cost more than the query.
    ///
    /// The whole port rather than its kind, because a folder's manifest asks two questions
    /// of the same row — whether the child is pinned, and what its content hashes to — and
    /// the hash comes back in the row the kind was already read from.
    public func selectChildPorts(parentNodeID: ObjectID,
                                 nameSymbolID: ObjectID) throws -> [ObjectID: OutputPort] {
        try selecting { db in
            var result: [ObjectID: OutputPort] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.nodeID AS nodeID, p.valueKind AS valueKind, p.dataObjectHash AS dataObjectHash
                FROM OutputPort p
                JOIN Node n ON n.id = p.nodeID
                WHERE n.parentNodeID = ? AND p.nameSymbolID = ?
                """, arguments: [parentNodeID, nameSymbolID])
            for row in rows {
                let raw: UInt8 = row["valueKind"]
                guard let valueKind = OutputPort.ValueKind(rawValue: raw) else {
                    continue
                }
                let nodeID: ObjectID = row["nodeID"]
                result[nodeID] = OutputPort(nodeID: nodeID,
                                            nameSymbolID: nameSymbolID,
                                            valueKind: valueKind,
                                            dataObjectHash: row["dataObjectHash"])
            }
            return result
        }
    }

    public func selectAll() throws -> [NodeRecord] {
        Debug.warn("expensive selectAllNodes call")
        return try selecting { db in try NodeRecord.fetchAll(db) }
    }

    public func select(nodeID: ObjectID) throws -> NodeRecord {
        guard let node = try find(nodeID: nodeID) else {
            throw DatabaseLayer.DatabaseError.nodeNotFound
        }
        return node
    }

    /// `select(nodeID:)` for callers to whom absence is an answer — a node deleted by an
    /// earlier step of the same pass, a parent that may be gone. Nil for a missing row;
    /// a failure of the database itself still throws, so `try?` is never the right way to
    /// ask this question.
    public func find(nodeID: ObjectID) throws -> NodeRecord? {
        try selecting { db in try NodeRecord.fetchOne(db, id: nodeID) }
    }

    public func select(parentNodeID: ObjectID) throws -> [NodeRecord] {
        try selecting { db in
            try NodeRecord.filter(NodeRecord.Columns.parentNodeID == parentNodeID).fetchAll(db)
        }
    }

    public func select(named name: String, parentNodeID: ObjectID?) throws -> [NodeRecord] {
        try selecting { db in
            try NodeRecord.filter(NodeRecord.Columns.name == name &&
                            NodeRecord.Columns.parentNodeID == parentNodeID).fetchAll(db)
        }
    }

    /// Every node on the path `names` below `ancestorNodeID`, in one query: the ancestor's
    /// own row at depth 0, its children named `names[0]` at depth 1, their children named
    /// `names[1]`, and so on, each with its rows for the ports in `portSymbolIDs`. Ordered by
    /// depth; the walk stops where a name is missing, so a path that exists only in part
    /// comes back as the part that exists, and an ancestor with no row as nothing. An empty
    /// path reads nothing and returns nothing.
    ///
    /// The ancestor comes back so that a caller holding its id from a cache can check the
    /// id still names the node it thinks, in the same query rather than a select of its own.
    ///
    /// One query rather than a select per component, because a push resolves a file's
    /// folders on every file it sends: six folders deep, a lookup and a pin read per folder
    /// was a dozen round trips through the serialised database for a file that had not
    /// changed, and most of an unchanged push of a large tree (B-131). The ports ride along
    /// for the same reason — what a caller asks of a folder on the way down is its pin.
    ///
    /// Every row with a matching name comes back, not the first: a folder holding two
    /// children of one name is a graph the caller has to refuse, and it cannot refuse what
    /// it was not shown. Below such a pair the walk continues under both.
    public func selectPath(below ancestorNodeID: ObjectID,
                           names: [String],
                           portSymbolIDs: [ObjectID]) throws -> [NodePathStep] {
        guard !names.isEmpty else {
            return []
        }

        var arguments: [DatabaseValueConvertible] = []
        for (index, name) in names.enumerated() {
            arguments.append(index + 1)
            arguments.append(name)
        }
        arguments.append(ancestorNodeID)

        // An empty `IN ()` is not SQL, and no port asked for is no port joined.
        var portFilter = "0"
        if !portSymbolIDs.isEmpty {
            portFilter = "p.nameSymbolID IN (\(portSymbolIDs.map { _ in "?" }.joined(separator: ", ")))"
            arguments.append(contentsOf: portSymbolIDs)
        }

        // Not a cached statement, though the text depends only on the depth: tried on a
        // push, a cached one was prepared again on every use (`sqlite3Reprepare` under
        // `sqlite3_step`) — each read through `DatabaseQueue` runs statements of its own
        // around the block, and the cached one did not survive them — so it saved nothing.
        let segmentValues = names.map { _ in "(?, ?)" }.joined(separator: ", ")
        let rows = try selecting { db in
            try Row.fetchAll(db, sql: """
                WITH RECURSIVE
                    segment(depth, name) AS (VALUES \(segmentValues)),
                    chain(depth, nodeID) AS (
                        SELECT 0, ?
                        UNION ALL
                        SELECT segment.depth, child.id
                        FROM chain
                        JOIN segment ON segment.depth = chain.depth + 1
                        JOIN Node child ON child.parentNodeID = chain.nodeID AND child.name = segment.name
                    )
                SELECT chain.depth AS pathDepth, n.*,
                       p.nodeID AS portNodeID, p.nameSymbolID AS portSymbolID,
                       p.valueKind AS portValueKind, p.dataObjectHash AS portDataObjectHash
                FROM chain
                JOIN Node n ON n.id = chain.nodeID
                LEFT JOIN OutputPort p ON p.nodeID = n.id AND \(portFilter)
                ORDER BY chain.depth, n.id
                """, arguments: StatementArguments(arguments))
        }

        // A node comes back once per port it has a row for, consecutively by the ordering.
        var steps: [NodePathStep] = []
        for row in rows {
            let nodeID: ObjectID = row["id"]
            if steps.last?.node.id != nodeID {
                steps.append(NodePathStep(depth: row["pathDepth"], node: try NodeRecord(row: row), ports: [:]))
            }
            guard let portNodeID: ObjectID = row["portNodeID"],
                  let rawValueKind: UInt8 = row["portValueKind"],
                  let valueKind = OutputPort.ValueKind(rawValue: rawValueKind) else {
                continue
            }
            let portSymbolID: ObjectID = row["portSymbolID"]
            steps[steps.count - 1].ports[portSymbolID] = OutputPort(nodeID: portNodeID,
                                                                    nameSymbolID: portSymbolID,
                                                                    valueKind: valueKind,
                                                                    dataObjectHash: row["portDataObjectHash"])
        }
        return steps
    }

    /// `ancestorNodeID` and every node of `kind` below it reached through nodes of that
    /// kind — a folder and its subfolders at every depth — each with its parent, its name
    /// and its rows for the ports in `portSymbolIDs`, in one query. Ordered by depth, so a
    /// parent always comes before its children; the ancestor is at depth 0 whatever its kind.
    ///
    /// One query rather than a walk, because a push compares a whole tree's folders with
    /// the disk before it sends anything (B-132): a select per folder is a round trip per
    /// folder, and what a push of an unchanged tree costs is exactly that walk.
    public func selectSubtree(below ancestorNodeID: ObjectID,
                              kind: UInt,
                              portSymbolIDs: [ObjectID]) throws -> [NodeSubtreeRow] {
        var arguments: [DatabaseValueConvertible] = [ancestorNodeID, kind]
        var portFilter = "0"
        if !portSymbolIDs.isEmpty {
            portFilter = "p.nameSymbolID IN (\(portSymbolIDs.map { _ in "?" }.joined(separator: ", ")))"
            arguments.append(contentsOf: portSymbolIDs)
        }

        // `CROSS JOIN` fixes the order, the subtree outermost: left to itself, the planner
        // walked each step by the index on `kind` — every folder in the graph per folder in
        // the subtree — and read the rest by scanning `Node`, which cost more than the push
        // it was saving.
        let rows = try selecting { db in
            try Row.fetchAll(db, sql: """
                WITH RECURSIVE
                    subtree(depth, nodeID) AS (
                        SELECT 0, ?
                        UNION ALL
                        SELECT subtree.depth + 1, child.id
                        FROM subtree
                        CROSS JOIN Node child ON child.parentNodeID = subtree.nodeID AND child.kind = ?
                    )
                SELECT subtree.depth AS subtreeDepth, n.id AS id, n.parentNodeID AS parentNodeID, n.name AS name,
                       p.nameSymbolID AS portSymbolID, p.valueKind AS portValueKind,
                       p.dataObjectHash AS portDataObjectHash
                FROM subtree
                CROSS JOIN Node n ON n.id = subtree.nodeID
                LEFT JOIN OutputPort p ON p.nodeID = n.id AND \(portFilter)
                ORDER BY subtree.depth, n.id
                """, arguments: StatementArguments(arguments))
        }

        // A node comes back once per port it has a row for, consecutively by the ordering.
        var result: [NodeSubtreeRow] = []
        for row in rows {
            let nodeID: ObjectID = row["id"]
            if result.last?.id != nodeID {
                result.append(NodeSubtreeRow(id: nodeID, parentNodeID: row["parentNodeID"], name: row["name"],
                                             depth: row["subtreeDepth"], ports: [:]))
            }
            guard let portSymbolID: ObjectID = row["portSymbolID"],
                  let rawValueKind: UInt8 = row["portValueKind"],
                  let valueKind = OutputPort.ValueKind(rawValue: rawValueKind) else {
                continue
            }
            result[result.count - 1].ports[portSymbolID] = OutputPort(nodeID: nodeID,
                                                                      nameSymbolID: portSymbolID,
                                                                      valueKind: valueKind,
                                                                      dataObjectHash: row["portDataObjectHash"])
        }
        return result
    }

    public func select(identity: String) throws -> [NodeRecord] {
        try selecting { db in
            try NodeRecord.filter(NodeRecord.Columns.identity == identity).fetchAll(db)
        }
    }

    public func select(kind: UInt, named name: String, parentNodeID: ObjectID?) throws -> [NodeRecord] {
        try selecting { db in
            try NodeRecord.filter(NodeRecord.Columns.kind == kind &&
                            NodeRecord.Columns.name == name &&
                            NodeRecord.Columns.parentNodeID == parentNodeID).fetchAll(db)
        }
    }

    /// Every node of one kind, unqualified by name or parent.
    ///
    /// `kind` is indexed, so unlike `selectAll()` this does not scan the whole table —
    /// safe to call for a common kind as well as a rare one.
    public func select(kind: UInt) throws -> [NodeRecord] {
        try selecting { db in
            try NodeRecord.filter(NodeRecord.Columns.kind == kind).fetchAll(db)
        }
    }

    public func insert(_ node: NodeRecord) throws -> ObjectID {
        try write { db in
            try node.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func insertOrUpdate(_ node: NodeRecord) throws {
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
    public func update(_ node: NodeRecord) throws {
        try write { db in
            try db.execute(
                sql: """
                     UPDATE Node
                        SET parentNodeID      = ?,
                            kind              = ?,
                            name              = ?,
                            encodedProperties = ?,
                            identity         = ?
                      WHERE id = ?
                     """,
                arguments: [
                    node.parentNodeID,
                    node.kind,
                    node.name,
                    NodeRecord.encodeProperties(node.properties),
                    node.identity,
                    node.id
                ]
            )
        }
    }

    public func delete(nodeID: ObjectID) throws -> Bool {
        try write { db in
            let result = try NodeRecord.deleteOne(db, id: nodeID)
            try OutputPort.filter(OutputPort.Columns.nodeID == nodeID).deleteAll(db)
            return result
        }
    }
}

extension NodeRecord: CustomStringConvertible {
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
