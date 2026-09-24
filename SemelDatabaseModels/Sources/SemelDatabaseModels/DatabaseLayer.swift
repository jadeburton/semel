//
//  Database.swift
//  semel
//
//  Created by Jade Burton on 06.02.26.
//

import Foundation
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

    // ── The boundary every access goes through ───────────────────────────────
    //
    // Every GRDB error is born inside one of these three, so this is where a failure of
    // the machine (`SQLITE_FULL`, `SQLITE_IOERR`, …) is told apart from one of the
    // statement and translated into `DatabaseVolumeError`, the unrecoverable kind. A
    // nested call inside a transaction throws straight through to the outer boundary,
    // which translates once; translating an already-translated error is a no-op.

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try translatingVolumeFailures {
            if let wrapper = DatabaseLayer.currentDB {
                return try block(wrapper.db)
            }
            return try dbQueue.read { db in try block(db) }
        }
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try translatingVolumeFailures {
            if let wrapper = DatabaseLayer.currentDB {
                return try block(wrapper.db)
            }
            return try dbQueue.write { db in try block(db) }
        }
    }

    /// `reporting` is the file the translated error names. It defaults to this database's
    /// own, which is the file every read and write is against; a caller writing somewhere
    /// else — a copy taken aside — passes that destination, so the message names the file
    /// the failure was about.
    private func translatingVolumeFailures<T>(reporting pathToReport: String? = nil,
                                              _ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch {
            throw DatabaseVolumeError.translating(error, filePath: pathToReport ?? filePath)
        }
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

        return try translatingVolumeFailures {
            try dbQueue.write { db in
                try DatabaseLayer.$currentDB.withValue(TaskLocalDatabase(db: db)) {
                    try work()
                }
            }
        }
    }

    /// Execute `work` against one read of the database, so every query it makes — directly
    /// or through a data accessor — sees one state of the graph.
    ///
    /// `withTransaction` is the write tool and takes the writer queue with it, which is
    /// the wrong price for a caller that only wants to look. This is the reader's twin:
    /// `DatabaseQueue` serialises every access, so the block holds the queue and no writer
    /// can interleave with it.
    ///
    /// Two separate `selectAll`s are *not* one state. A caller that reads the nodes and
    /// then the wires can be handed a wire whose endpoint node was created between the
    /// two reads, and conclude the graph is broken when it is merely busy. Inside one of
    /// these that cannot happen.
    ///
    /// A write reached from inside takes this same read connection, and SQLite refuses it
    /// with `SQLITE_READONLY` — so the read-only intent is enforced rather than merely
    /// stated. That code otherwise means the *volume* is read-only, which the boundary
    /// translates into an unrecoverable `DatabaseVolumeError` that stops the process and
    /// tells the reader to check permissions on their disk. Inside a snapshot that
    /// diagnosis would be wrong twice over, so the code is re-read here as what it
    /// actually is: `WriteInsideReadSnapshotError`, an ordinary error naming the caller's
    /// bug, which fails the operation instead of the machine.
    ///
    /// Nesting works both ways round, and only one of them is useful.
    /// `withReadSnapshot` inside `withTransaction` participates in that write transaction,
    /// as every other nesting here does. `withTransaction` inside a snapshot is the
    /// reverse: the inner call finds a connection already published, so it opens no
    /// transaction of its own and takes the read connection — every write in it is
    /// refused, and there is no rollback scope, because there is nothing to roll back.
    /// Reach for this only where nothing writes.
    public func withReadSnapshot<T>(_ work: () throws -> T) throws -> T {
        if DatabaseLayer.currentDB != nil {
            return try work()
        }

        return try translatingVolumeFailures {
            try dbQueue.read { db in
                try DatabaseLayer.$currentDB.withValue(TaskLocalDatabase(db: db)) {
                    do {
                        return try work()
                    } catch {
                        throw Self.namingAWriteInsideASnapshot(error)
                    }
                }
            }
        }
    }

    /// Re-reads a `SQLITE_READONLY` raised inside a snapshot as the caller's write rather
    /// than as the volume's state. The inner boundary has already translated it, so the
    /// GRDB error is unwrapped from that translation before it is judged; anything else
    /// passes through as it was.
    private static func namingAWriteInsideASnapshot(_ error: Error) -> Error {
        let databaseError = (error as? DatabaseVolumeError)?.underlying ?? (error as? GRDB.DatabaseError)
        guard let databaseError, databaseError.resultCode == .SQLITE_READONLY else {
            return error
        }
        return WriteInsideReadSnapshotError(underlying: databaseError)
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

    // ── Copying the file aside ───────────────────────────────────────────────

    /// Where a copy of this database taken with `suffix` goes: beside the original, under
    /// the same name with `suffix` appended, and with `-2`, `-3` … appended again while a
    /// file of that name is already there. A copy taken earlier is evidence, and evidence
    /// is never overwritten — two copies taken inside the same second are two files. Nil
    /// for an in-memory database, which has no file and no state worth keeping past the
    /// process.
    public func pathForCopyAside(suffix: String) -> String? {
        guard let filePath else {
            return nil
        }
        let preferredPath = filePath + suffix
        guard FileManager.default.fileExists(atPath: preferredPath) else {
            return preferredPath
        }
        var discriminator = 2
        while FileManager.default.fileExists(atPath: "\(preferredPath)-\(discriminator)") {
            discriminator += 1
        }
        return "\(preferredPath)-\(discriminator)"
    }

    /// Writes a self-contained copy of this database to `destinationPath`, which
    /// `pathForCopyAside(suffix:)` answers.
    ///
    /// Through SQLite's own backup rather than a file copy: the database runs in WAL mode,
    /// so committed rows live in `graph.sqlite-wal` until a checkpoint moves them, and
    /// copying the one file alone would leave them out. The copy is written without WAL,
    /// so it is one file that opens anywhere.
    ///
    /// Inside the same boundary every other access goes through, so a full or read-only
    /// volume is reported as the machine's failure and not as a bare SQLite code — naming
    /// the copy, since that is the file being written. What a failed copy wrote is removed:
    /// half a database looks like evidence and is not.
    public func copyAside(to destinationPath: String) throws {
        try translatingVolumeFailures(reporting: destinationPath) {
            do {
                let destination = try DatabaseQueue(path: destinationPath)
                try dbQueue.backup(to: destination)
            } catch {
                for path in [destinationPath, destinationPath + "-wal",
                             destinationPath + "-shm", destinationPath + "-journal"] {
                    try? FileManager.default.removeItem(atPath: path)
                }
                throw error
            }
        }
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
