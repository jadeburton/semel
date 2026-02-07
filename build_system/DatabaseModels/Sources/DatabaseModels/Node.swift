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
    public func selectAllNodes() throws -> [Node] {
        try dbQueue.read { db in
            try Node.fetchAll(db)
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

    public func insertNode(_ node: Node) throws {
        try dbQueue.write { db in
            try node.insert(db)
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
