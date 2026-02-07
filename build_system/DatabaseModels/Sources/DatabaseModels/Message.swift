import Foundation
import GRDB

public struct Message: Codable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: ObjectID?
    public var targetNodeID: ObjectID
    public var targetPort: UInt8
    public var oneShotDataObjectID: ObjectID?
    public var priority: Int

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Message", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("priority", .integer).indexed().notNull()
                t.column("targetNodeID", .integer).notNull().indexed()
                t.column("targetPort", .integer).notNull()
                t.column("oneShotDataObjectID", .integer)
            }
        }
    }
}

extension DatabaseLayer {
    // Select all Messages, ordered by priority (highest first) and then by ID (oldest first)
    public func selectAllMessages() throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .order(Column("priority").desc, Column("id").asc)
                .fetchAll(db)
        }
    }

    // Select all Messages associated with the given Node, ordered by priority (highest first) and then by ID (oldest first)
    public func selectMessages(for nodeID: ObjectID) throws -> [Message] {
        try dbQueue.read { db in
            try Message
                .filter(Column("targetNodeID") == nodeID)
                .order(Column("priority").desc, Column("id").asc)
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
