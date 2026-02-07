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

extension Database {
    public static func selectAllNodes(dbQueue: DatabaseQueue) throws -> [Node] {
        []
    }

    public static func selectNodes(named name: String, dbQueue: DatabaseQueue) throws -> [Node] {
        []
    }

    public static func selectNodes(kind: UInt, dbQueue: DatabaseQueue) throws -> [Node] {
        []
    }

    public static func insertNode(_ node: Node, dbQueue: DatabaseQueue) throws {
    }

    public static func updateNode(_ node: Node, dbQueue: DatabaseQueue) throws {
    }

    public static func deleteNode(nodeID: ObjectID, dbQueue: DatabaseQueue) throws {
    }
}
