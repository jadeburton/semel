// CacheHome.swift
// SemelCacheServer
//
// The folder a cache server keeps everything in: its settings, its index, its objects, and
// the lock that says a server is running there. Named by `--home` on every command, never
// taken from the environment, so two caches on one machine are two folders and nothing else.

import Foundation

public struct CacheHome: Equatable {

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    /// `semel.cache.config`: the settings, in the `key value` form the Semel home's files use.
    public var configurationFile: URL {
        folder.appendingPathComponent("semel.cache.config", isDirectory: false)
    }

    /// The index of entries: the cache's tables in a SQLite database of their own.
    public var indexFile: URL {
        folder.appendingPathComponent("index.sqlite", isDirectory: false)
    }

    /// The objects, in the node kit's content-addressed store.
    public var objectsFolder: URL {
        folder.appendingPathComponent("objects", isDirectory: true)
    }

    /// Held by a running server for as long as it runs.
    public var lockFile: URL {
        folder.appendingPathComponent("semel.cache.lock", isDirectory: false)
    }

    /// Makes the folder if nothing has.
    public func create() throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw CacheHomeError.cannotCreate(folder.path, reason: error.localizedDescription)
        }
    }

    /// Takes the home's lock, or says who holds it: nil when a server is running there. A
    /// lock rather than a file's presence, so a server that crashed leaves nothing a later
    /// one has to clean up — the kernel lets go of a dead process's lock.
    public func lock() throws -> CacheHomeLock? {
        try create()
        let descriptor = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw CacheHomeError.cannotLock(lockFile.path, reason: String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(descriptor)
            guard failure == EWOULDBLOCK else {
                throw CacheHomeError.cannotLock(lockFile.path, reason: String(cString: strerror(failure)))
            }
            return nil
        }
        return CacheHomeLock(descriptor: descriptor)
    }
}

/// The home's lock, held until released or the process ends.
public final class CacheHomeLock {

    private var descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public func release() {
        guard descriptor >= 0 else {
            return
        }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

public enum CacheHomeError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case cannotCreate(String, reason: String)
    case cannotLock(String, reason: String)

    public var description: String {
        switch self {
        case .cannotCreate(let path, let reason):
            return "the cache's home \(path) could not be made: \(reason)"
        case .cannotLock(let path, let reason):
            return "the cache's lock \(path) could not be taken: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}
