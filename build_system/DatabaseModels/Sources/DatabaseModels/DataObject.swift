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
    public func selectDataObject(hash: String) throws -> [DataObject] {
        []
    }

    public func insertDataObject(_ dataObject: DataObject) throws {
    }

    public func deleteDataObject(dataObjectID: ObjectID) throws -> Bool {
        false
    }
}


public struct Sha256 {
    public static func hash(_ data: [UInt8]) -> String {
        let digest = SHA256.hash(data: Data(data))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

