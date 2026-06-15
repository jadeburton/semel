//
//  Symbol.swift
//  DatabaseModels
//
//  Created by Jade Burton on 11.06.26.
//

import Foundation
import GRDB

public struct Symbol: Codable, FetchableRecord, PersistableRecord, Equatable {
    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
    }

    public var id: ObjectID?
    public var name: String

    public init(id: ObjectID? = nil, name: String) {
        self.id = id
        self.name = name
    }

    // Port uses a natural key instead of the usual "id" surrogate key.
    public static func createTable(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.create(table: "Symbol", options: .ifNotExists) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
            }
        }
    }
}

extension DatabaseLayer {
    public func selectSymbol(symbolID: ObjectID) throws -> Symbol? {
        try read { db in
            try Symbol.filter(Symbol.Columns.id == symbolID).fetchOne(db)
        }
    }

    public func selectSymbolID(name: String) throws -> ObjectID? {
        try read { db in
            try Symbol.filter(Symbol.Columns.name == name).fetchOne(db)?.id
        }
    }

    public func insertSymbol(name: String) throws -> ObjectID {
        let symbol = Symbol(name: name)
        return try write { db in
            try symbol.insert(db)
            return db.lastInsertedRowID
        }
    }

    public func deleteSymbol(symbolID: ObjectID) throws -> Bool {
        try write { db in
            try Symbol.filter(Symbol.Columns.id == symbolID).deleteAll(db) > 0
        }
    }
}

public extension Symbol {
    func description() -> String {
        "Symbol: name=\(name), id=\(id ?? -1)"
    }
}

// MARK: - Resolving a DataToken back to bytes

enum SymbolError: Error {
    case symbolNotFoundByID
}

extension String {
    public func asSymbolID() -> ObjectID {
        if let objectID = try! DatabaseLayer.shared.selectSymbolID(name: self) {
            return objectID
        } else {
            return try! DatabaseLayer.shared.insertSymbol(name: self)
        }
    }
}

extension ObjectID {
    public func resolveSymbolAsObject() -> Symbol {
        guard let symbol = try? DatabaseLayer.shared.selectSymbol(symbolID: self) else {
            fatalError("Invalid SymbolID / failed to load Symbol")
        }
        return symbol
    }

    public func resolveSymbol() -> String {
        resolveSymbolAsObject().name
    }
}
