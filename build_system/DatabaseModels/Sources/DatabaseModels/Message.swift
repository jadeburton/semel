import Foundation
import GRDB

public struct Message: Codable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: ObjectID?
    public var targetNodeID: ObjectID
    public var wireID: ObjectID
    public var dataObjectHash: DataObjectHash

    public init(id: ObjectID? = nil, targetNodeID: ObjectID, wireID: ObjectID, dataObjectHash: DataObjectHash) {
        self.id = id
        self.targetNodeID = targetNodeID
        self.wireID = wireID
        self.dataObjectHash = dataObjectHash
    }

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Message", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("targetNodeID", .integer).notNull().indexed()
                t.column("wireID", .integer).notNull()
                t.column("dataObjectHash", .text).notNull()
            }
        }
    }
}

extension DatabaseLayer {
    // Select all Messages, ordered by ID (oldest first)
    public func selectAllMessages(limit: Int) throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .order(Column("id").asc)
                .fetchAll(db) // TODO limit
        }
    }

    // Select all Messages associated with the given Node, ordered by ID (oldest first)
    public func selectMessages(for nodeID: ObjectID) throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .filter(Column("targetNodeID") == nodeID)
                .order(Column("id").asc)
                .fetchAll(db)
        }
    }

    // Select all Messages associated with the given Node, ordered by ID (oldest first)
    public func selectMessages(for nodeID: ObjectID, wireID: ObjectID) throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .filter(Column("targetNodeID") == nodeID && Column("wireID") == wireID)
                .order(Column("id").asc)
                .fetchAll(db)
        }
    }

    public func insertMessage(_ message: Message) throws {
        try dbQueue.write { db in
            try message.insert(db)
        }
    }

    public func updateMessage(_ message: Message) throws {
        try dbQueue.write { db in
            try message.update(db)
        }
    }

    public func deleteMessage(messageID: ObjectID) throws -> Bool {
        try dbQueue.write { db in
            try Message.deleteOne(db, id: messageID)
        }
    }
}

public extension Message {
    func description() -> String {
        "Message \(id ?? -1): targetNodeID=\(targetNodeID), wireID=\(wireID), dataObjectHash=\(dataObjectHash)"
    }
}
