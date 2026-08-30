//
//  Symbol.swift
//  SemelDatabaseModels
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

// MARK: - Resolving a DataObjectHash back to bytes

enum SymbolError: Error {
    case symbolNotFoundByID
}

extension String {
    /// Interns this name in the Symbol table and returns its id.
    ///
    /// Throws rather than trapping: this writes to the database, which fails for
    /// ordinary reasons.  A failed insert should fail the operation that needed the
    /// symbol, not abort the process.
    /// The id for this name, recording it if the database has not seen it before.
    ///
    /// Does not throw. Every port name, wire name and file name in the graph goes through
    /// here, so a `try` at each of the forty-odd call sites would suggest a decision the
    /// caller could make — and there is none. `insertOrGetID` is `INSERT OR IGNORE` followed
    /// by a `SELECT` that force-unwraps its result: the only ways it fails are the volume
    /// being full, read-only or unreachable, and the next name looked up hits the same wall.
    public func asSymbolID() -> ObjectID {
        if let id = symbolCache.id(for: self) { return id }
        do {
            let id = try DatabaseLayer.shared.symbol.insertOrGetID(name: self)
            symbolCache.store(name: self, id: id)
            return id
        } catch {
            FatalErrors.fail(SymbolStoreError.cannotRecord(name: self, underlying: error))
        }
    }
}

/// Failures of the symbol table, which sits under everything else in the graph.
public enum SymbolStoreError: UnrecoverableError {
    /// A name could not be written to the database.
    case cannotRecord(name: String, underlying: Error)
    /// An id that is referenced but has no row — the database disagrees with itself.
    case unknownSymbolID(ObjectID)

    public var unrecoverableDescription: String {
        switch self {
        case .cannotRecord(let name, let underlying):
            return """
                Could not record the name '\(name)' in the database.

                \(underlying.localizedDescription)

                Every port, wire and file in the graph is named through this table, so the
                build cannot proceed. Check free space and permissions on the volume holding
                the database.
                """

        case .unknownSymbolID(let id):
            return """
                The database refers to name #\(id), which it does not contain.

                Nothing can repair this from inside the build: the graph and the table it is
                named through disagree. Reset the build system to rebuild both from the input
                file system.
                """
        }
    }
}

extension ObjectID {
    public func resolveSymbolAsObject() -> Symbol {
        if let name = symbolCache.name(for: self) {
            return Symbol(id: self, name: name)
        }
        guard let symbol = try? DatabaseLayer.shared.symbol.select(symbolID: self) else {
            FatalErrors.fail(SymbolStoreError.unknownSymbolID(self))
        }
        symbolCache.store(name: symbol.name, id: self)
        return symbol
    }

    public func resolveSymbol() -> String {
        symbolCache.name(for: self) ?? resolveSymbolAsObject().name
    }
}
