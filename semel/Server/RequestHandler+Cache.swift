// RequestHandler+Cache.swift
// semel
//
// `cache` and `cache limit` (B-148): the engine's report of its cache, as records. `cache
// server` and `cache identity` (B-153): the shared cache the home names, put in force.

import Foundation
import SemelCache
import SemelCacheClient
import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol

extension RequestHandler {

    static func cacheSummary(_ report: CacheReport, shared: SharedCacheSummary) -> CacheSummary {
        CacheSummary(entries: report.entries.count, bytes: report.bytes, limit: report.limit,
                     limitIsDefault: report.limitIsDefault, lastTrim: report.lastTrim.flatMap(trimRecord),
                     shared: shared)
    }

    // MARK: - The shared cache (B-153)

    /// The shared cache the settings name, not yet started, over the process's object
    /// store; nil when they name no server.
    public static func sharedCache(for configuration: EngineConfiguration) -> SharedCache? {
        guard let server = configuration.cacheServer else {
            return nil
        }
        return SharedCache(remote: SocketRemoteCache(server: server),
                           identity: configuration.cacheIdentity,
                           objectStore: DataObjectStore.shared)
    }

    /// `cache server` and `cache identity`: the file written first, as `cache limit` writes
    /// it — a setting the file could not keep would hold only until the server stopped — then
    /// a new shared cache put in force, which connects on its own thread. Changing the
    /// identity connects again too: the name is said in the hello.
    func changeSharedCache(_ change: (inout EngineConfiguration) -> Void) throws -> SharedCacheSummary {
        var configuration = try EngineConfiguration.read(from: engineConfigurationFile)
        change(&configuration)
        try configuration.write(to: engineConfigurationFile)
        engine.useSharedCache(Self.sharedCache(for: configuration))
        return Self.sharedCacheSummary(configuration: configuration, cache: engine.sharedCache)
    }

    /// The settings as the file holds them, and the cache in force's connection and figures.
    static func sharedCacheSummary(configuration: EngineConfiguration, cache: SharedCache?) -> SharedCacheSummary {
        guard let cache else {
            return SharedCacheSummary(server: configuration.cacheServer, identity: configuration.cacheIdentity,
                                      connection: nil, figures: nil)
        }
        let figures = cache.figures()
        return SharedCacheSummary(
            server:     configuration.cacheServer,
            identity:   configuration.cacheIdentity,
            connection: connection(cache.state),
            figures:    SharedCacheFigures(hits: figures.hits, misses: figures.misses, failures: figures.failures,
                                           declined: figures.declined, unavailable: figures.unavailable,
                                           bytesFetched: ByteCount(bytes: figures.bytesFetched),
                                           entriesSent: figures.entriesSent, bytesSent: ByteCount(bytes: figures.bytesSent),
                                           queued: figures.queued, dropped: figures.dropped,
                                           writeFailures: figures.writeFailures,
                                           measuredBytesPerSecond: figures.rateIsAssumed ? nil : Int(figures.bytesPerSecond),
                                           measuredMicrosecondsPerRequest: figures.secondsPerRequest > 0
                                               ? Int(figures.secondsPerRequest * 1_000_000) : nil,
                                           lastFailure: figures.lastFailure))
    }

    private static func connection(_ state: SharedCache.ConnectionState) -> SharedCacheConnection {
        switch state {
        case .connecting, .stopped:
            return .connecting
        case .connected(.readWrite):
            return .readWrite
        case .connected(.readOnly):
            return .readOnly
        case .down(let reason):
            return .down(reason: reason)
        case .rejected(let reason):
            return .rejected(reason: reason)
        }
    }

    /// Largest first, which is what a reader of a cache over its limit looks for; the key
    /// breaks ties so the list is the same twice.
    static func cacheEntryRecords(_ report: CacheReport) -> [CacheEntryRecord] {
        report.entries
            .sorted { ($1.bytes, $0.hash) < ($0.bytes, $1.hash) }
            .map { size in
                CacheEntryRecord(key: CacheKey(hash: size.hash), nodeType: size.nodeType, bytes: ByteCount(bytes: size.bytes), cost: size.cost,
                                 usedByLastSettle: size.lastUse >= report.lastUsingSettle, heldByNode: size.heldByNode)
            }
    }

    /// Nil for a trim that evicted nothing: there is nothing to say about it.
    static func trimRecord(_ trim: CacheTrim) -> CacheTrimRecord? {
        guard !trim.evictions.isEmpty else {
            return nil
        }
        return CacheTrimRecord(evicted: trim.evictions.count, freed: trim.freed, bytesAfter: trim.bytesAfter, limit: trim.limit,
                               evictedByType: trim.evictedByType.map { CacheEvictedType(nodeType: $0.nodeType, count: $0.count) })
    }
}
