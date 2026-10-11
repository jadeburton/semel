// CacheIndexDatabase.swift
// SemelCache
//
// The cache's tables in a database of their own: a cache server's index. The same tables
// as in the engine's graph database, created by the same `createTable`, so the one
// `SQLiteCacheStore` reads and writes both; what differs is everything else the graph's
// database holds, which this one does not.
//
// Tuned for answering quickly, with durability traded for it and never consistency. The
// log is write-ahead and synced at its checkpoints only (`synchronous=NORMAL`): a crash of
// the process or the machine can lose the last transactions, and can never leave the file
// corrupt — which `OFF` could, after a power failure. Pages are cached generously and the
// file is mapped, so a read of an entry's bytes is a copy out of memory. SQLite's own
// checkpoint after a commit is switched off, because it would run on whichever write
// crossed the threshold and make that request wait; the owner checkpoints when it is idle
// (`checkpoint()`).

import Foundation
import GRDB
import SemelDatabaseModels

public final class CacheIndexDatabase: CacheDatabase {

    /// Where the index lives on disk; nil for one in memory.
    public let filePath: String?

    private let writer: any DatabaseWriter

    /// The index in the file at `filePath`, made with the cache's tables when there is none.
    /// A pool: readers run beside the one writer, so an entry's bytes are read while a
    /// batch commits.
    public init(filePath: String) throws {
        var configuration = Configuration()
        // Another process — `semel-cache purge` beside a server that is starting — may hold
        // the write lock for a moment; waiting for it is better than failing.
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { connection in
            try connection.execute(sql: "PRAGMA synchronous=NORMAL")
            try connection.execute(sql: "PRAGMA cache_size=-65536")          // 64 MB of pages
            try connection.execute(sql: "PRAGMA mmap_size=1073741824")       // map up to 1 GB
            try connection.execute(sql: "PRAGMA temp_store=MEMORY")
            try connection.execute(sql: "PRAGMA wal_autocheckpoint=0")
        }
        let pool = try DatabasePool(path: filePath, configuration: configuration)
        try CacheEntry.createTable(in: pool)
        self.writer   = pool
        self.filePath = filePath
    }

    /// An index in memory, gone with the process: what a test runs the server's handlers
    /// over.
    public init() throws {
        let queue = try DatabaseQueue()
        try CacheEntry.createTable(in: queue)
        self.writer   = queue
        self.filePath = nil
    }

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try translatingVolumeFailures { try writer.read(block) }
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try translatingVolumeFailures { try writer.write(block) }
    }

    /// Moves what the log holds into the database file, without waiting on a reader. Run
    /// when nothing is waiting to be written, so no request waits on it.
    public func checkpoint() throws {
        guard filePath != nil else {
            return
        }
        try translatingVolumeFailures {
            try writer.writeWithoutTransaction { connection in
                try connection.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
            }
        }
    }

    private func translatingVolumeFailures<T>(_ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch {
            throw DatabaseVolumeError.translating(error, filePath: filePath)
        }
    }
}
