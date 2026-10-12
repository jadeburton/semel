// CacheAdministration.swift
// SemelCacheServer
//
// `status` and `purge`. A running server holds its index in memory and is the one place
// it may change, so with a server running both go through it, over the protocol, at the
// address its home's file names. With none — the home's lock free — they open the home
// themselves, holding the lock meanwhile so no server starts under them.

import Foundation
import SemelCache
import SemelNodeKit
import SemelProtocol
import SemelTransport

public enum CacheAdministrationError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The home is locked by a server that does not answer where its file says it listens.
    case serverUnreachable(address: String, reason: String)
    case refused(String)
    case unexpectedReply(String)

    public var description: String {
        switch self {
        case .serverUnreachable(let address, let reason):
            return "a server holds this home but does not answer at \(address): \(reason)"
        case .refused(let reason):
            return "the server refused: \(reason)"
        case .unexpectedReply(let reply):
            return "the server answered something else: \(reply)"
        }
    }

    public var errorDescription: String? { description }
}

public enum CacheAdministration {

    // MARK: - status

    /// The lines `semel-cache status` prints.
    public static func status(home: CacheHome) throws -> [String] {
        let configuration = try CacheServerConfiguration.read(from: home.configurationFile)
        let limit = configuration.limit ?? CacheServerConfiguration.defaultLimit
        guard let lock = try home.lock() else {
            let (address, connection) = try connectToRunningServer(home: home, configuration: configuration, wantsWrite: false)
            defer { connection.close() }
            guard case .status(let status) = try ask(connection, .status) else {
                throw CacheAdministrationError.unexpectedReply("not a status")
            }
            return ["semel-cache in \(home.folder.path), answering at \(address)",
                    "entries  \(status.entries)",
                    "bytes    \(status.bytes) of a \(status.limit) limit",
                    "hits     \(status.hits) since the server started",
                    "misses   \(status.misses) since the server started"]
        }
        defer { lock.release() }
        var entries = 0
        var bytes   = 0
        if FileManager.default.fileExists(atPath: home.indexFile.path) {
            // The store holds its database weakly, so the database is kept alive here for as
            // long as the store is asked.
            let database = try CacheIndexDatabase(filePath: home.indexFile.path)
            let rows = SQLiteCacheStore(database: database)
            try withExtendedLifetime(database) {
                entries = try rows.count()
                bytes   = try rows.account().bytes
            }
        }
        return ["semel-cache in \(home.folder.path), not running",
                "entries  \(entries)",
                "bytes    \(ByteCount(bytes: bytes)) of a \(limit) limit",
                "hits and misses are counted by a running server"]
    }

    // MARK: - purge

    /// The lines `semel-cache purge` prints.
    public static func purge(home: CacheHome, target: CachePurgeTarget) throws -> [String] {
        let configuration = try CacheServerConfiguration.read(from: home.configurationFile)
        let request: CacheRequest
        switch target {
        case .key(let key):
            request = .purge(key: key)
        case .all:
            request = .purgeAll
        }
        guard let lock = try home.lock() else {
            let (_, connection) = try connectToRunningServer(home: home, configuration: configuration, wantsWrite: true)
            defer { connection.close() }
            return try describe(purged(by: ask(connection, request)), target: target)
        }
        defer { lock.release() }
        let store = try CacheServerStore(database: CacheIndexDatabase(filePath: home.indexFile.path),
                                         objectStore: DataObjectStore(storeRoot: home.objectsFolder),
                                         limit: configuration.limit ?? CacheServerConfiguration.defaultLimit,
                                         requestsPerUse: CacheServer.requestsPerUse)
        defer { store.close() }
        let (response, _) = store.complete(store.prepare(request, body: nil))
        guard case .cache(let cacheResponse) = response else {
            throw CacheAdministrationError.unexpectedReply("\(response)")
        }
        return try describe(purged(by: cacheResponse), target: target)
    }

    private static func purged(by response: CacheResponse) throws -> Int {
        guard case .purged(let entries) = response else {
            throw CacheAdministrationError.unexpectedReply("\(response)")
        }
        return entries
    }

    private static func describe(_ entries: Int, target: CachePurgeTarget) -> [String] {
        switch target {
        case .key(let key):
            return [entries == 0 ? "no entry under \(key)" : "purged the entry under \(key)"]
        case .all:
            return ["purged \(entries) entr\(entries == 1 ? "y" : "ies") and every object"]
        }
    }

    // MARK: - The running server

    private static func connectToRunningServer(home: CacheHome, configuration: CacheServerConfiguration,
                                               wantsWrite: Bool) throws -> (String, SocketConnection) {
        guard let listen = configuration.listen else {
            throw CacheServerError.noListenAddress(file: home.configurationFile.path)
        }
        let address = CacheListenAddress(host: listen.localHost, port: listen.port)
        let connection: SocketConnection
        do {
            connection = try SocketConnection.connect(to: .tcp(host: address.host, port: address.port), timeout: 5)
        } catch {
            throw CacheAdministrationError.serverUnreachable(address: address.description, reason: "\(error)")
        }
        do {
            let (reply, _) = try connection.send(.hello(Hello(role: .cache, wantsWrite: wantsWrite)), body: nil)
            switch reply {
            case .hello(.cacheAccepted(.readOnly)) where wantsWrite:
                throw CacheAdministrationError.refused("the server lets no client write; stop it and purge the home, or serve with --writers all")
            case .hello(.cacheAccepted):
                return (address.description, connection)
            default:
                throw CacheAdministrationError.unexpectedReply("\(reply)")
            }
        } catch {
            connection.close()
            throw error
        }
    }

    private static func ask(_ connection: SocketConnection, _ request: CacheRequest) throws -> CacheResponse {
        let (reply, _) = try connection.send(.cache(request), body: nil)
        switch reply {
        case .cache(.refused(let reason)):
            throw CacheAdministrationError.refused("\(reason)")
        case .cache(let response):
            return response
        default:
            throw CacheAdministrationError.unexpectedReply("\(reply)")
        }
    }
}
