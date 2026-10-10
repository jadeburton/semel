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
        try requireDatabaseLayer().read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try requireDatabaseLayer().write(block)
    }

    /// The layer this accessor reads and writes through. Held weakly, because the layer
    /// holds its accessors, so an accessor kept past its layer finds nothing here.
    private func requireDatabaseLayer() throws -> DatabaseLayer {
        guard let databaseLayer else {
            throw DatabaseLayer.DatabaseError.layerReleased(accessor: String(describing: Self.self))
        }
        return databaseLayer
    }
}

public final class DatabaseLayer {

    public lazy var node             = NodeDataAccess(databaseLayer: self)
    public lazy var wire             = WireDataAccess(databaseLayer: self)
    public lazy var symbol           = SymbolDataAccess(databaseLayer: self)
    public lazy var outputPort       = OutputPortDataAccess(databaseLayer: self)
    public lazy var cacheEntry       = CacheEntryDataAccess(databaseLayer: self)
    public lazy var metadata         = MetadataDataAccess(databaseLayer: self)
    public lazy var artifactSnapshot = ArtifactSnapshotDataAccess(databaseLayer: self)

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
        /// Set by `withTransactionPerStep`: a `withTransaction` reached inside it is a
        /// savepoint, where inside any other transaction it simply takes part.
        var nestsAsSavepoints = false
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
        /// A data accessor used after the `DatabaseLayer` that made it was released, named
        /// by its type.
        case layerReleased(accessor: String)
        /// The cache's one account row is missing: `createTables` inserts it, so a database
        /// without it was damaged by hand.
        case cacheAccountMissing
        /// A savepoint that returned without running the work inside it.
        case savepointNotRun
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
        // Already inside a transaction — participate without opening a new one, or, inside
        // `withTransactionPerStep`, open a savepoint in its place.
        if let wrapper = DatabaseLayer.currentDB {
            guard wrapper.nestsAsSavepoints else {
                return try work()
            }
            return try Self.inSavepoint(of: wrapper.db, work)
        }

        return try translatingVolumeFailures {
            try dbQueue.write { db in
                try DatabaseLayer.$currentDB.withValue(TaskLocalDatabase(db: db)) {
                    try work()
                }
            }
        }
    }

    /// One write transaction around a run of steps that would each have been transactions
    /// of their own, committed once at the end: what a batch of pushed files is recorded
    /// in. Each step's writes cost a commit, and with it a sync of the log, when it is its
    /// own; together they cost one.
    ///
    /// The steps keep the boundaries they would have had. A `withTransaction` reached
    /// directly inside this one is a savepoint rather than a part of it, so a step that
    /// throws out of one undoes that one's writes and nothing else, as its own transaction
    /// would have, and the caller can catch it and go on to the next step. A
    /// `withTransaction` inside that savepoint takes part in it, as one inside a transaction
    /// always has. A bare `write` is given no savepoint: SQLite undoes a statement that
    /// fails by itself, and writes that must stand or fall together belong in a
    /// `withTransaction`. What does not keep its boundaries is an error thrown out of
    /// `work`: it rolls back every step, the finished ones too — which is why a caller
    /// catches a step's failure inside, and lets out only the machine's, a full disk or a
    /// read-only volume, on which the server stops anyway.
    public func withTransactionPerStep<T>(_ work: () throws -> T) throws -> T {
        if DatabaseLayer.currentDB != nil {
            return try withTransaction(work)
        }

        return try translatingVolumeFailures {
            try dbQueue.write { db in
                try DatabaseLayer.$currentDB.withValue(TaskLocalDatabase(db: db, nestsAsSavepoints: true)) {
                    try work()
                }
            }
        }
    }

    /// `work` as one unit that a throw undoes and nothing else: a savepoint of the
    /// transaction already open, whichever kind it is, or a transaction of its own outside
    /// one. For a step a caller means to catch and go on from — a fold that fails stays
    /// marked, with nothing of it written, while the folds beside it commit.
    ///
    /// `withTransaction` will not do for that inside a transaction it did not open: it takes
    /// part in that one, so a throw caught by the caller leaves whatever the step had
    /// written before it threw. A volume failure is translated here rather than at the
    /// outer boundary, so a caller that catches an ordinary failure still lets the
    /// machine's through.
    public func withSavepoint<T>(_ work: () throws -> T) throws -> T {
        guard let wrapper = DatabaseLayer.currentDB else {
            return try withTransaction(work)
        }
        return try translatingVolumeFailures {
            try Self.inSavepoint(of: wrapper.db, work)
        }
    }

    /// `work` inside a savepoint of `db`, with what it reaches taking part in that savepoint
    /// rather than opening another: one level, the boundary a transaction of its own drew.
    private static func inSavepoint<T>(of db: Database, _ work: () throws -> T) throws -> T {
        var completed: Result<T, Error> = .failure(DatabaseError.savepointNotRun)
        try db.inSavepoint {
            completed = .success(try DatabaseLayer.$currentDB.withValue(TaskLocalDatabase(db: db)) {
                try work()
            })
            return .commit
        }
        return try completed.get()
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
    /// stated. Outside a snapshot that code means the *volume* is read-only, and the
    /// boundary translates it into an unrecoverable `DatabaseVolumeError` that stops the
    /// process and sends the reader to check permissions on their disk. Inside one it is
    /// ambiguous: a WAL reader writes too — to the `-shm` and `-wal` siblings, when it is
    /// first to open them after they grow or has to recover them after a crash — so a
    /// volume that cannot take that bookkeeping refuses a plain read with the same code.
    /// Stopping would be the wrong answer to the caller's bug and only one of the two
    /// possible answers to the disk's, so the code is re-read here as
    /// `WriteInsideReadSnapshotError`, an ordinary error that names both causes and fails
    /// the operation instead of the machine.
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

    /// Re-reads a `SQLITE_READONLY` raised inside a snapshot as the ambiguous thing it is,
    /// rather than as the volume's state alone. The inner boundary has already translated
    /// it, so the GRDB error is unwrapped from that translation before it is judged;
    /// anything else passes through as it was.
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
        try ArtifactSnapshot.createTable(dbQueue: dbQueue)
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
