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

public struct SymbolDataAccess: DataAccessType {
    public weak var databaseLayer: DatabaseLayer?

    public init(databaseLayer: DatabaseLayer) {
        self.databaseLayer = databaseLayer
    }

    public func select(symbolID: ObjectID) throws -> Symbol? {
        try read { db in
            try Symbol.filter(Symbol.Columns.id == symbolID).fetchOne(db)
        }
    }

    public func selectID(name: String) throws -> ObjectID? {
        try read { db in
            try Symbol.filter(Symbol.Columns.name == name).fetchOne(db)?.id
        }
    }

    public func insert(name: String) throws -> ObjectID {
        let symbol = Symbol(name: name)
        return try write { db in
            try symbol.insert(db)
            return db.lastInsertedRowID
        }
    }

    /// Atomically inserts the symbol if it doesn't exist, then returns its ID.
    /// Uses INSERT OR IGNORE so concurrent callers inserting the same name never
    /// race: the second writer simply gets back the ID that the first one created.
    public func insertOrGetID(name: String) throws -> ObjectID {
        try write { db in
            // INSERT OR IGNORE is a no-op when the name already exists (UNIQUE constraint),
            // so the subsequent SELECT always finds exactly one row.
            try db.execute(sql: "INSERT OR IGNORE INTO Symbol (name) VALUES (?)",
                           arguments: [name])
            return try Int64.fetchOne(db, sql: "SELECT id FROM Symbol WHERE name = ?",
                                      arguments: [name])!
        }
    }

    public func delete(symbolID: ObjectID) throws -> Bool {
        try write { db in
            try Symbol.filter(Symbol.Columns.id == symbolID).deleteAll(db) > 0
        }
    }
}

extension Symbol: CustomStringConvertible {
    public var description: String {
        "Symbol: name=\(name), id=\(id ?? -1)"
    }
}

// MARK: - Symbol cache

private final class SymbolCache: @unchecked Sendable {
    private let lock  = NSLock()
    private var nameToID: [String: ObjectID] = [:]
    private var idToName: [ObjectID: String] = [:]

    func id(for name: String) -> ObjectID? {
        lock.withLock { nameToID[name] }
    }

    func name(for id: ObjectID) -> String? {
        lock.withLock { idToName[id] }
    }

    func store(name: String, id: ObjectID) {
        lock.withLock {
            nameToID[name] = id
            idToName[id]   = name
        }
    }

    func removeAll() {
        lock.withLock {
            nameToID.removeAll()
            idToName.removeAll()
        }
    }
}

private let symbolCache = SymbolCache()

/// Drops every interned name↔id mapping.  A SymbolID only means anything within the
/// database that issued it, so this must run whenever `DatabaseLayer.shared` is
/// replaced — otherwise ids interned against the previous database leak into the new
/// one, where the matching Symbol rows do not exist.
func resetSymbolCache() {
    symbolCache.removeAll()
}

// MARK: - Resolving a DataToken back to bytes

enum SymbolError: Error {
    case symbolNotFoundByID
}

extension String {
    /// Interns this name in the Symbol table and returns its id.
    ///
    /// Throws rather than trapping: this writes to the database, which fails for
    /// ordinary reasons.  A failed insert should fail the operation that needed the
    /// symbol, not abort the process.
    public func asSymbolID() throws -> ObjectID {
        if let id = symbolCache.id(for: self) { return id }
        let id = try DatabaseLayer.shared.symbol.insertOrGetID(name: self)
        symbolCache.store(name: self, id: id)
        return id
    }
}

extension ObjectID {
    public func resolveSymbolAsObject() -> Symbol {
        if let name = symbolCache.name(for: self) {
            return Symbol(id: self, name: name)
        }
        guard let symbol = try? DatabaseLayer.shared.symbol.select(symbolID: self) else {
            fatalError("Invalid SymbolID / failed to load Symbol")
        }
        symbolCache.store(name: symbol.name, id: self)
        return symbol
    }

    public func resolveSymbol() -> String {
        symbolCache.name(for: self) ?? resolveSymbolAsObject().name
    }
}
