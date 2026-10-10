// CacheMessages.swift
// SemelProtocol
//
// What `cache` and `cache limit` carry (B-148): the cache's entries with their sizes, its
// total against the home's limit, and what the last trim evicted. Records, not lines: the
// client renders them.

import Foundation
import SemelNodeKit

/// One cached build as `cache` lists it.
public struct CacheEntryRecord: Codable, Equatable, Sendable {
    public let key: String
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

    public init(key: String, nodeType: String, bytes: ByteCount, cost: Int, usedByLastSettle: Bool, heldByNode: Bool) {
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

    public init(entries: Int, bytes: ByteCount, limit: ByteCount, limitIsDefault: Bool, lastTrim: CacheTrimRecord?) {
        self.entries        = entries
        self.bytes          = bytes
        self.limit          = limit
        self.limitIsDefault = limitIsDefault
        self.lastTrim       = lastTrim
    }
}
