import Foundation
import CryptoKit
import GRDB

public struct DataObject: Codable, FetchableRecord, PersistableRecord {
    public var hash: String
    public var content: [UInt8]

    public init(hash: String, content: [UInt8]) {
        self.hash = hash
        self.content = content
    }

    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "DataObject", options: .ifNotExists) { t in
                t.column("hash", .text).notNull().primaryKey()
                t.column("content", .blob).notNull()
            }
        }
    }
}

extension DatabaseLayer {
    public func selectAllDataObjects() throws -> [DataObject] {
        try read { db in try DataObject.fetchAll(db) }
    }

    public func selectDataObject(hash: String) throws -> DataObject? {
        try read { db in
            try DataObject.filter(Column("hash") == hash).fetchOne(db)
        }
    }

    public func insertDataObject(_ dataObject: DataObject) throws {
        try write { db in try dataObject.insert(db) }
    }

    public func deleteDataObject(hash: String) throws -> Bool {
        try write { db in
            try DataObject.filter(Column("hash") == hash).deleteAll(db) > 0
        }
    }
}

public extension DataObject {
    func description() -> String {
        "DataObject hash=0x\(hash), size=\(content.count) byte(s), content=0x\(content.prefix(16).asHex())\(content.count > 16 ? "..." : "")"
    }
}

extension Sequence<UInt8> {
    public func asHex() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

public struct Sha256 {
    public static func hash(_ data: [UInt8]) -> String {
        let hash = [UInt8](SHA256.hash(data: Data(data)))
        let final = (hash.count < data.count) ? hash : data
        return final.asHex()
    }
}
