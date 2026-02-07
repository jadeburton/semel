import Foundation
import CryptoKit
import GRDB

public struct DataObject: Codable, Identifiable, FetchableRecord, PersistableRecord {
    public var id: ObjectID?
    public var hash: String
    public var content: [UInt8]

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "DataObject", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("hash", .text).notNull().indexed().unique()
                t.column("content", .blob).notNull()
            }
        }
    }
}

extension DatabaseLayer {
    public func selectAllDataObjects() throws -> [DataObject] {
        try dbQueue.read { db in
            try DataObject
                .fetchAll(db)
        }
    }

    public func selectDataObjectID(hash: String) throws -> ObjectID? {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM DataObject WHERE hash = ? LIMIT 1", arguments: [hash])
        }
    }

    public func selectDataObject(hash: String) throws -> DataObject? {
        try dbQueue.read { db in
            try DataObject.filter(Column("hash") == hash).fetchOne(db)
        }
    }

    public func selectDataObjectByID(_ id: ObjectID) throws -> DataObject? {
        try dbQueue.read { db in
            try DataObject.fetchOne(db, id: id)
        }
    }

    public func insertDataObject(_ dataObject: DataObject) throws -> ObjectID {
        try dbQueue.write { db in
            try dataObject.insert(db)
            return db.lastInsertedRowID as ObjectID
        }
    }

    public func deleteDataObject(dataObjectID: ObjectID) throws -> Bool {
        try dbQueue.write { db in
            try DataObject.deleteOne(db, id: dataObjectID)
        }
    }
}

public extension DataObject {
    func description() -> String {
        "DataObject \(id ?? -1): hash=0x\(hash), size=\(content.count) byte(s), content=0x\(content.map { String(format: "%02x", $0) }.joined())"
    }
}

public struct Sha256 {
    public static func hash(_ data: [UInt8]) -> String {
        let digest = SHA256.hash(data: Data(data))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

