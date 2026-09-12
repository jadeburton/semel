//
//  Database.swift
//  semel
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
    public lazy var metadata   = MetadataDataAccess(databaseLayer: self)

    public static var shared: DatabaseLayer!

    public let dbQueue: DatabaseQueue

    /// Where the database lives on disk; nil for an in-memory one. Reported to the user when
    /// the file has to be deleted by hand.
    public let filePath: String?

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

    @TaskLocal static var currentDB: TaskLocalDatabase?

    // ── Internal helpers used by every extension method ──────────────────────

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        if let wrapper = DatabaseLayer.currentDB {
            return try block(wrapper.db)
        }
        return try dbQueue.read { db in try block(db) }
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        if let wrapper = DatabaseLayer.currentDB {
            return try block(wrapper.db)
        }
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
        if DatabaseLayer.currentDB != nil {
            return try work()
        }

        return try dbQueue.write { db in
            try DatabaseLayer.$currentDB.withValue(TaskLocalDatabase(db: db)) {
                try work()
            }
        }
    }

    // ── Initialisers ─────────────────────────────────────────────────────────

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
        self.filePath = filePath

        try DatabaseLayer.createTables(dbQueue: dbQueue)

        resetSymbolCache()
        Self.shared = self
    }

    /// Creates an anonymous in-memory database — suitable for unit and integration tests.
    public init() throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        dbQueue = try DatabaseQueue(configuration: config)
        filePath = nil

        try DatabaseLayer.createTables(dbQueue: dbQueue)

        resetSymbolCache()
        Self.shared = self
    }

    private static func createTables(dbQueue: DatabaseQueue) throws {
        try NodeRecord.createTable(dbQueue: dbQueue)
        try Wire.createTable(dbQueue: dbQueue)
        try CacheEntry.createTable(dbQueue: dbQueue)
        try Symbol.createTable(dbQueue: dbQueue)
        try OutputPort.createTable(dbQueue: dbQueue)
        try Metadata.createTable(dbQueue: dbQueue)
    }

    // ── Schema fingerprint ───────────────────────────────────────────────────
    //
    // `createTables` is IF NOT EXISTS, so an existing database keeps the tables it was
    // created with whatever the code now says. The only honest comparison is between what
    // the file holds and what the code would create from nothing.

    /// The schema this database actually has: every CREATE statement SQLite recorded,
    /// in a fixed order. SQLite's own bookkeeping tables (`sqlite_sequence` appears on the
    /// first AUTOINCREMENT insert) are left out — they are not part of the schema.
    public func schemaFingerprint() throws -> String {
        try Self.schemaFingerprint(of: dbQueue)
    }

    /// The schema this build of Semel creates, taken from a throwaway in-memory database.
    public static func expectedSchemaFingerprint() throws -> String {
        let scratch = try DatabaseQueue()
        try createTables(dbQueue: scratch)
        return try schemaFingerprint(of: scratch)
    }

    private static func schemaFingerprint(of dbQueue: DatabaseQueue) throws -> String {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT sql FROM sqlite_master
                WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
                ORDER BY type, name
                """).joined(separator: "\n")
        }
    }

    /// Legacy helper kept for compatibility; prefer `withTransaction`.
    public func doTransaction(work: () throws -> ()) throws {
        try withTransaction(work)
    }
}
