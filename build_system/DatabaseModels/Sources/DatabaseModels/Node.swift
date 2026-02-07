// Node model moved into DatabaseModels package

import GRDB

public struct Node: Codable, Identifiable, FetchableRecord, PersistableRecord {
    public enum Columns {
        public static let kind = Column(CodingKeys.kind)
        public static let name = Column(CodingKeys.name)
        public static let configuration = Column(CodingKeys.configuration)
    }

    public var id: ObjectID?
    public var kind: UInt
    public var name: String?
    public var configuration: String? // JSON

    public init(id: ObjectID? = nil, kind: UInt, name: String? = nil, configuration: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.configuration = configuration
    }

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Node", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .integer).notNull()
                t.column("name", .text)
                t.column("configuration", .text)
            }
        }
    }
}

extension DatabaseLayer {

    // Returns all Nodes that have at least one Message targeting them, ordered by ID (oldest first)
    public func selectAllNodesWithInputMessages(limit: Int) throws -> [Node] {
        try dbQueue.read { db in
            try Node
                .joining(required: Node.hasMany(Message.self,
                                                using: ForeignKey(["targetNodeID"], to: ["id"])))
                .group(Column("id"))
                .order(Column("id").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func selectAllNodes() throws -> [Node] {
        try dbQueue.read { db in
            try Node.fetchAll(db)
        }
    }

    public func selectNodeByID(_ nodeID: ObjectID) throws -> Node? {
        try dbQueue.read { db in
            try Node.fetchOne(db, id: nodeID)
        }
    }

    public func selectNodes(named name: String) throws -> [Node] {
        try dbQueue.read { db in
            try Node.filter(Node.Columns.name == name).fetchAll(db)
        }
    }

    public func selectNodes(kind: UInt) throws -> [Node] {
        try dbQueue.read { db in
            try Node.filter(Node.Columns.kind == kind).fetchAll(db)
        }
    }

    public func insertNode(_ node: Node) throws -> ObjectID {
        try dbQueue.write { db in
            try node.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func insertOrReplaceNode(_ node: Node) throws {
        try dbQueue.write { db in
            try node.save(db)
        }
    }

    public func updateNode(_ node: Node) throws {
        try dbQueue.write { db in
            try node.update(db)
        }
    }

    public func deleteNode(nodeID: ObjectID) throws -> Bool {
        try dbQueue.write { db in
            try Node.deleteOne(db, id: nodeID)
        }
    }
}

public extension Node {
    func description() -> String {
        "Node \(id ?? -1): kind \(kind), name=\(name ?? "nil")"
    }
}
