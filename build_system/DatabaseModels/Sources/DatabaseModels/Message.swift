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

extension Database {
    // Select all Messages, ordered by priority (highest first) and then by ID (oldest first)
    public static func selectAllMessages(dbQueue: DatabaseQueue) throws -> [Node] {
        []
    }

    // Select all Messages associated with the given Node, ordered by priority (highest first) and then by ID (oldest first)
    public static func selectMessages(for nodeID: ObjectID, dbQueue: DatabaseQueue) throws -> [Message] {
        []
    }

    public static func insertMessage(_ message: Message, dbQueue: DatabaseQueue) throws {
    }

    public static func updateMessage(_ message: Message, dbQueue: DatabaseQueue) throws {
    }

    public static func deleteMessage(messageID: ObjectID, dbQueue: DatabaseQueue) throws {
    }
}
