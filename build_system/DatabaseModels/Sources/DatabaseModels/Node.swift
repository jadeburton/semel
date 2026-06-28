// Node model moved into DatabaseModels package

import GRDB

public struct Node: Codable, Identifiable, FetchableRecord, PersistableRecord {
    public enum Columns {
        public static let kind = Column(CodingKeys.kind)
        public static let name = Column(CodingKeys.name)
        public static let configuration = Column(CodingKeys.configuration)
        public static let parentNodeID = Column(CodingKeys.parentNodeID)
        public static let scheduled = Column(CodingKeys.scheduled)
        public static let searchKey = Column(CodingKeys.searchKey)
    }

    public var id: ObjectID?
    public var parentNodeID: ObjectID?
    public var kind: UInt
    public var name: String?
    public var configuration: String? // JSON
    public var scheduled: Bool
    public var searchKey: String?

    public init(id: ObjectID? = nil, parentNodeID: ObjectID? = nil, kind: UInt, name: String? = nil, configuration: String? = nil, scheduled: Bool = false, searchKey: String?) {
        self.id = id
        self.parentNodeID = parentNodeID
        self.kind = kind
        self.name = name
        self.configuration = configuration
        self.scheduled = scheduled
        self.searchKey = searchKey
    }

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Node", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("parentNodeID", .integer)
                t.column("kind", .integer).notNull()
                t.column("name", .text)
                t.column("configuration", .text)
                t.column("scheduled", .integer).indexed().notNull()
                t.column("searchKey", .text).unique()
            }
        }
    }
}

extension DatabaseLayer {

    public func selectAllScheduledNodes(limit: Int) throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.scheduled == true).fetchAll(db)
        }
    }

    public func selectAllNodes() throws -> [Node] {
        print("WARNING: expensive selectAllNodes call")
        return try read { db in try Node.fetchAll(db) }
    }

    public func selectNodeByID(_ nodeID: ObjectID) throws -> Node? {
        try read { db in try Node.fetchOne(db, id: nodeID) }
    }

    public func selectNodes(parentNodeID: ObjectID) throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.parentNodeID == parentNodeID).fetchAll(db)
        }
    }

    public func selectNodes(named name: String, parentNodeID: ObjectID?) throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.name == name &&
                            Node.Columns.parentNodeID == parentNodeID).fetchAll(db)
        }
    }

    public func selectNodes(searchKey: String) throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.searchKey == searchKey).fetchAll(db)
        }
    }

    public func selectNodes(kind: UInt, named name: String, parentNodeID: ObjectID?) throws -> [Node] {
        try read { db in
            try Node.filter(Node.Columns.kind == kind &&
                            Node.Columns.name == name &&
                            Node.Columns.parentNodeID == parentNodeID).fetchAll(db)
        }
    }

    public func insertNode(_ node: Node) throws -> ObjectID {
        try write { db in
            try node.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func insertOrReplaceNode(_ node: Node) throws {
        try write { db in try node.save(db) }
    }

    public func updateNode(_ node: Node) throws {
        try write { db in try node.update(db) }
    }

    public func deleteNode(nodeID: ObjectID) throws -> Bool {
        try write { db in try Node.deleteOne(db, id: nodeID) }
    }
}

extension Node: CustomStringConvertible {
    public var description: String {
        "Node \(id ?? -1): kind \(kind), name=\(name ?? "nil"), scheduled=\(scheduled)"
    }
}
