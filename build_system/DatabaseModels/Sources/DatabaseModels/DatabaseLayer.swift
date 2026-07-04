//
//  Database.swift
//  build_system
//
//  Created by Jade Burton on 06.02.26.
//

@preconcurrency import GRDB

public protocol DataAccessType {
    init(databaseLayer: DatabaseLayer)
    var databaseLayer: DatabaseLayer? { get }
}

public extension DataAccessType {
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try databaseLayer!.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try databaseLayer!.write(block)
    }
}

public final class DatabaseLayer {
    public lazy var node       = NodeDataAccess(databaseLayer: self)
    public lazy var wire       = WireDataAccess(databaseLayer: self)
    public lazy var symbol     = SymbolDataAccess(databaseLayer: self)
    public lazy var outputPort = OutputPortDataAccess(databaseLayer: self)
    public lazy var cacheEntry = CacheEntryDataAccess(databaseLayer: self)

    public static var shared: DatabaseLayer!

    public let dbQueue: DatabaseQueue

    // ── Current transaction connection ──────────────────────────────────────
    //
    // When `withTransaction` is active this holds the open `Database` connection
    // so that every DatabaseLayer method can participate in the same transaction
    // without re-entering the DatabaseQueue.
    //
    // @TaskLocal propagates through synchronous call stacks within the scope of
    // `withValue`, so all helpers called from inside `withTransaction` see it
    // automatically — no parameter threading required.
    //
    // `Database` is not `Sendable` (GRDB intentionally prevents it from crossing
    // task boundaries), so we wrap it in a thin `@unchecked Sendable` box.
    // Safety is upheld because the wrapped connection is only ever read within the
    // same `withValue` scope on the originating task — it never actually crosses
    // a concurrency boundary.

    struct TaskLocalDatabase: @unchecked Sendable {
        let db: Database
    }

    @TaskLocal static var currentDB: TaskLocalDatabase? = nil

    // ── Internal helpers used by every extension method ──────────────────────

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        if let wrapper = DatabaseLayer.currentDB { return try block(wrapper.db) }
        return try dbQueue.read { db in try block(db) }
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        if let wrapper = DatabaseLayer.currentDB { return try block(wrapper.db) }
        return try dbQueue.write { db in try block(db) }
    }

    // ── Public transaction API ───────────────────────────────────────────────

    public enum DatabaseError: Error {
        case nodeNotFound
        case nodePortNotFound
        case wireNotFound
    }

    /// Execute `work` inside a single GRDB write transaction.
    ///
    /// All `DatabaseLayer` methods called — directly or transitively — from
    /// within `work` share the same `Database` connection, so:
    ///   • There is no reentrancy: no "Database methods are not reentrant" crash.
    ///   • The whole operation is atomic: if `work` throws, GRDB rolls back
    ///     every write made inside the transaction automatically.
    ///   • Nested calls to `withTransaction` are safe: the inner call detects
    ///     that `currentDB` is already set and runs `work` directly without
    ///     opening a second transaction.
    public func withTransaction<T>(_ work: () throws -> T) throws -> T {
        // Already inside a transaction — participate without opening a new one.
        if DatabaseLayer.currentDB != nil { return try work() }

        return try dbQueue.write { db in
            try DatabaseLayer.$currentDB.withValue(TaskLocalDatabase(db: db)) {
                try work()
            }
        }
    }

    // ── Initialiser ─────────────────────────────────────────────────────────

    public init(filePath: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            try db.execute(sql: "PRAGMA cache_size=-65536")  // 64 MB page cache
            try db.execute(sql: "PRAGMA temp_store=MEMORY")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        dbQueue = try DatabaseQueue(path: filePath, configuration: config)

        try Node.createTable(dbQueue: dbQueue)
        try Wire.createTable(dbQueue: dbQueue)
        try CacheEntry.createTable(dbQueue: dbQueue)
        try Symbol.createTable(dbQueue: dbQueue)
        try OutputPort.createTable(dbQueue: dbQueue)

        assert(Self.shared == nil)
        Self.shared = self
    }

    /// Legacy helper kept for compatibility; prefer `withTransaction`.
    public func doTransaction(work: () throws -> ()) throws {
        try withTransaction(work)
    }
}
