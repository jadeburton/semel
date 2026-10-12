// CacheServer.swift
// SemelCacheServer
//
// `semel-cache serve`: the home's lock taken, its settings written from the arguments and
// read back, its store opened, and a TCP listener whose every connection is a
// `CacheService`. The listener is `SemelTransport`'s `FrameServer`, the one the engine's
// server answers through; what a request means is this package's.

import Foundation
import SemelCache
import SemelNodeKit
import SemelProtocol
import SemelTransport

public enum CacheServerError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Another server holds the home's lock.
    case alreadyRunning(home: String)
    /// Neither the arguments nor the home's file say where to listen.
    case noListenAddress(file: String)

    public var description: String {
        switch self {
        case .alreadyRunning(let home):
            return "a cache server is already running in \(home)"
        case .noListenAddress(let file):
            return "no address to listen at: give --listen <host:port>, or a 'listen' line in \(file)"
        }
    }

    public var errorDescription: String? { description }
}

public final class CacheServer {

    /// Entry requests per use of the cache, for eviction's order (`CacheServerStore`). Large
    /// enough that a whole build's worth of lookups by one engine is one or two uses.
    public static let requestsPerUse = 10_000

    public let home: CacheHome
    public let configuration: CacheServerConfiguration
    public let store: CacheServerStore

    private let lock: CacheHomeLock
    private let frameServer: FrameServer

    /// Takes the home: its lock, then its settings — the file with `overrides` put over it,
    /// written back — then its store. Listens nowhere yet.
    public init(home: CacheHome, overrides: CacheServerConfiguration) throws {
        guard let lock = try home.lock() else {
            throw CacheServerError.alreadyRunning(home: home.folder.path)
        }
        let configuration = try CacheServerConfiguration.read(from: home.configurationFile).overridden(by: overrides)
        guard let listen = configuration.listen else {
            throw CacheServerError.noListenAddress(file: home.configurationFile.path)
        }
        try configuration.write(to: home.configurationFile)

        let database = try CacheIndexDatabase(filePath: home.indexFile.path)
        let store = try CacheServerStore(database: database,
                                         objectStore: DataObjectStore(storeRoot: home.objectsFolder),
                                         limit: configuration.limit ?? CacheServerConfiguration.defaultLimit,
                                         requestsPerUse: Self.requestsPerUse)
        let handler = CacheRequestHandler(store: store, writers: configuration.writers ?? CacheServerConfiguration.defaultWriters)

        self.home          = home
        self.configuration = configuration
        self.store         = store
        self.lock          = lock
        self.frameServer   = FrameServer(endpoint: .tcp(host: listen.host, port: listen.port), name: "semel-cache") {
            CacheService(handler: handler)
        }
    }

    public func start() throws {
        try frameServer.start()
    }

    /// The port clients connect to: the one asked for, or the one given for port 0.
    public var port: UInt16? {
        frameServer.port
    }

    /// Closes every connection, writes what is queued, and lets the home go.
    public func stop() {
        frameServer.stop()
        store.close()
        lock.release()
    }

    /// What the server prints when it is listening.
    public var banner: [String] {
        let listen  = configuration.listen.map { CacheAddress(host: $0.host, port: port ?? $0.port) }
        let limit   = configuration.limit ?? CacheServerConfiguration.defaultLimit
        let writers = configuration.writers ?? CacheServerConfiguration.defaultWriters
        return ["semel-cache, protocol \(ProtocolVersion.current)",
                "Home:    \(home.folder.path)",
                "Listen:  \(listen?.description ?? "-")",
                "Limit:   \(limit) (\(limit.exactText))",
                "Writers: \(writers.rawValue)"]
    }
}
