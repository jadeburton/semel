// CacheMessages.swift
// SemelProtocol
//
// What `cache` and `cache limit` carry (B-148): the cache's entries with their sizes, its
// total against the home's limit, and what the last trim evicted. Records, not lines: the
// client renders them.

import Foundation
import SemelCache
import SemelNodeKit

/// One cached build as `cache` lists it.
public struct CacheEntryRecord: Codable, Equatable, Sendable {
    public let key: CacheKey
    public let nodeType: String
    /// What the entry alone holds in the store: what evicting it would give back.
    public let bytes: ByteCount
    /// How long the build took, in milliseconds.
    public let cost: Int
    /// Whether the last settle that used the cache wrote or read this entry.
    public let usedByLastSettle: Bool
    /// Whether a node of the graph holds values from this entry, which keeps it from
    /// being evicted.
    public let heldByNode: Bool

    public init(key: CacheKey, nodeType: String, bytes: ByteCount, cost: Int, usedByLastSettle: Bool, heldByNode: Bool) {
        self.key              = key
        self.nodeType         = nodeType
        self.bytes            = bytes
        self.cost             = cost
        self.usedByLastSettle = usedByLastSettle
        self.heldByNode       = heldByNode
    }
}

/// How many entries of one node type a trim evicted.
public struct CacheEvictedType: Codable, Equatable, Sendable {
    public let nodeType: String
    public let count: Int

    public init(nodeType: String, count: Int) {
        self.nodeType = nodeType
        self.count    = count
    }
}

/// What one trim evicted, and where it left the cache.
public struct CacheTrimRecord: Codable, Equatable, Sendable {
    public let evicted: Int
    public let freed: ByteCount
    public let bytesAfter: ByteCount
    public let limit: ByteCount
    public let evictedByType: [CacheEvictedType]

    public init(evicted: Int, freed: ByteCount, bytesAfter: ByteCount, limit: ByteCount, evictedByType: [CacheEvictedType]) {
        self.evicted       = evicted
        self.freed         = freed
        self.bytesAfter    = bytesAfter
        self.limit         = limit
        self.evictedByType = evictedByType
    }
}

/// The cache as a whole, as `cache` heads its list.
public struct CacheSummary: Codable, Equatable, Sendable {
    public let entries: Int
    public let bytes: ByteCount
    public let limit: ByteCount
    /// Whether no limit was set for this home and the engine's default applies.
    public let limitIsDefault: Bool
    /// The last trim that evicted something since the server started; nil when none has.
    public let lastTrim: CacheTrimRecord?
    /// The shared cache's settings, and its figures when the home names one (B-153).
    public let shared: SharedCacheSummary

    public init(entries: Int, bytes: ByteCount, limit: ByteCount, limitIsDefault: Bool, lastTrim: CacheTrimRecord?,
                shared: SharedCacheSummary) {
        self.entries        = entries
        self.bytes          = bytes
        self.limit          = limit
        self.limitIsDefault = limitIsDefault
        self.lastTrim       = lastTrim
        self.shared         = shared
    }
}

// MARK: - The shared cache (B-153)

/// Where an engine's connection to its shared cache stands.
public enum SharedCacheConnection: Codable, Equatable, Sendable {
    /// Not yet connected since the server started or the setting changed.
    case connecting
    case readWrite
    /// The cache serves this engine's lookups and takes none of its entries.
    case readOnly
    /// Unreachable, or lost; the engine connects again with a growing wait, and meanwhile
    /// every lookup is a local miss.
    case down(reason: String)
    /// The cache refused this engine's hello.
    case rejected(reason: String)
}

/// What an engine's shared cache has done since the server started or the setting changed.
public struct SharedCacheFigures: Codable, Equatable, Sendable {
    /// Lookups answered from the shared cache.
    public let hits: Int
    /// Lookups the shared cache had nothing for.
    public let misses: Int
    /// Lookups that failed on the way and were taken as misses.
    public let failures: Int
    /// Hits whose fetch was judged slower than the build, which ran instead.
    public let declined: Int
    /// Lookups made while the connection was down, answered as misses without asking.
    public let unavailable: Int
    public let bytesFetched: ByteCount
    public let entriesSent: Int
    public let bytesSent: ByteCount
    /// Entries waiting to be written, entries the full queue dropped, and entries whose
    /// write failed.
    public let queued: Int
    public let dropped: Int
    public let writeFailures: Int
    /// The link's rate the fetch policy weighs, in bytes a second; nil while nothing large
    /// enough has been fetched and the assumed rate stands.
    public let measuredBytesPerSecond: Int?
    /// What a request costs however small, in microseconds, as the fetches measured it; nil
    /// before any.
    public let measuredMicrosecondsPerRequest: Int?
    /// The last failure, in words.
    public let lastFailure: String?

    public init(hits: Int, misses: Int, failures: Int, declined: Int, unavailable: Int, bytesFetched: ByteCount,
                entriesSent: Int, bytesSent: ByteCount, queued: Int, dropped: Int, writeFailures: Int,
                measuredBytesPerSecond: Int?, measuredMicrosecondsPerRequest: Int?, lastFailure: String?) {
        self.hits                   = hits
        self.misses                 = misses
        self.failures               = failures
        self.declined               = declined
        self.unavailable            = unavailable
        self.bytesFetched           = bytesFetched
        self.entriesSent            = entriesSent
        self.bytesSent              = bytesSent
        self.queued                 = queued
        self.dropped                = dropped
        self.writeFailures          = writeFailures
        self.measuredBytesPerSecond = measuredBytesPerSecond
        self.measuredMicrosecondsPerRequest = measuredMicrosecondsPerRequest
        self.lastFailure            = lastFailure
    }
}

/// The shared cache as `cache` heads it: the two settings from the home's file, and, when a
/// server is named, the connection and the figures.
public struct SharedCacheSummary: Codable, Equatable, Sendable {
    public let server: CacheAddress?
    public let identity: String?
    /// Nil when no server is named.
    public let connection: SharedCacheConnection?
    public let figures: SharedCacheFigures?

    public init(server: CacheAddress?, identity: String?, connection: SharedCacheConnection?, figures: SharedCacheFigures?) {
        self.server     = server
        self.identity   = identity
        self.connection = connection
        self.figures    = figures
    }
}
