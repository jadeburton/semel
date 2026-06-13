//
//  PortName.swift
//  DatabaseModels
//
//  Created by Jade Burton on 11.06.26.
//

import Foundation
import GRDB

// Allows ports to be given a user-friendly string name without duplicating strings in the database.
// Examples: "inputSourceFile", "headerFile[0]", "headerFile[1]"
public struct PortName: Codable, FetchableRecord, PersistableRecord, Equatable {
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let index = Column(CodingKeys.index)
    }

    public var id: ObjectID?
    public var name: String
    public var index: Int?

    public init(id: ObjectID? = nil, name: String, index: Int?) {
        self.id = id
        self.name = name
        self.index = index
    }

    // Port uses a natural key instead of the usual "id" surrogate key.
    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "PortName", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().indexed()
                t.column("index", .integer)
                t.uniqueKey(["name", "index"])
            }
        }
    }
}

extension DatabaseLayer {
    public func selectPortName(portNameID: ObjectID) throws -> PortName? {
        try dbQueue.read { db in
            try PortName.filter(PortName.Columns.id == portNameID).fetchOne(db)
        }
    }

    public func selectPortNameID(name: String, index: Int? = nil) throws -> ObjectID? {
        try dbQueue.read { db in
            try PortName.filter(PortName.Columns.name == name &&
                               PortName.Columns.index == index).fetchOne(db)?.id
        }
    }

    public func insertPortName(name: String, index: Int? = nil) throws -> ObjectID {
        let portName = PortName(name: name, index: index)
        return try dbQueue.write { db in
            try portName.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func deletePortName(portNameID: ObjectID) throws -> Bool {
        try dbQueue.write { db in
            try PortName
                .filter(PortName.Columns.id == portNameID)
                .deleteAll(db) > 0
        }
    }
}

public extension PortName {
    var nameWithIndex: String {
        "\(name)\(index == nil ? "" : "[\(index!)]")"
    }

    func description() -> String {
        "PortName: name=\(nameWithIndex), id=\(id ?? -1)"
    }
}

// MARK: - Resolving a DataToken back to bytes

enum DataObjectError: Error {
    case dataObjectNotFoundByHash
}

enum PortNameError: Error {
    case portNameNotFoundByID
}

extension String {
    public func asPortNameID() -> ObjectID {
        let split = self.split(separator: "[", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(split[0])
        let index: Int? = split.count > 1 ? Int(split[1].dropLast()) : nil

        if let objectID = try! DatabaseLayer.shared.selectPortNameID(name: name, index: index) {
            return objectID
        } else {
            return try! DatabaseLayer.shared.insertPortName(name: name, index: index)
        }
    }
}

extension ObjectID {
    public func resolvePortNameAsObject() throws -> PortName {
        guard let portName = try DatabaseLayer.shared.selectPortName(portNameID: self) else {
            throw PortNameError.portNameNotFoundByID
        }
        return portName
    }

    public func resolvePortName() throws -> String {
        try resolvePortNameAsObject().nameWithIndex
    }
}
