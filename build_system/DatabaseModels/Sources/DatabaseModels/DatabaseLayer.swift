//
//  Database.swift
//  build_system
//
//  Created by Jade Burton on 06.02.26.
//

import GRDB

public final class DatabaseLayer {
    public static var shared: DatabaseLayer!

    let dbQueue: DatabaseQueue

    public enum DatabaseError: Error {
        case nodeNotFound
        case nodePortNotFound
        case wireNotFound
        case dataObjectNotFound
    }

    public init(filePath: String) throws {
        dbQueue = try DatabaseQueue(path: filePath)

        try Node.createTable(dbQueue: dbQueue)
        try Wire.createTable(dbQueue: dbQueue)
        try Message.createTable(dbQueue: dbQueue)
        try DataObject.createTable(dbQueue: dbQueue)
        try NodeOutputValue.createTable(dbQueue: dbQueue)

        assert(Self.shared == nil)
        Self.shared = self
    }

    public struct DatabaseTransaction {
        private weak var dbQueue: DatabaseQueue? = nil

        fileprivate init(dbQueue: DatabaseQueue) {
            self.dbQueue = dbQueue
        }

        public func commit() throws {
            try dbQueue!.inDatabase { db in
                try db.commit()
            }
        }

        public func rollback() throws {
            try dbQueue!.inDatabase { db in
                try db.rollback()
            }
        }
    }

    public func beginTransaction() throws -> DatabaseTransaction {
        try dbQueue.inDatabase { db in
            try db.beginTransaction()
        }
        return .init(dbQueue: dbQueue)
    }
}
