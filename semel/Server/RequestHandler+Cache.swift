// RequestHandler+Cache.swift
// semel
//
// `cache` and `cache limit` (B-148): the engine's report of its cache, as records.

import Foundation
import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol

extension RequestHandler {

    static func cacheSummary(_ report: CacheReport) -> CacheSummary {
        CacheSummary(entries: report.entries.count, bytes: report.bytes, limit: report.limit,
                     limitIsDefault: report.limitIsDefault, lastTrim: report.lastTrim.flatMap(trimRecord))
    }

    /// Largest first, which is what a reader of a cache over its limit looks for; the key
    /// breaks ties so the list is the same twice.
    static func cacheEntryRecords(_ report: CacheReport) -> [CacheEntryRecord] {
        report.entries
            .sorted { ($1.bytes, $0.hash) < ($0.bytes, $1.hash) }
            .map { size in
                CacheEntryRecord(key: size.hash, nodeType: size.nodeType, bytes: ByteCount(bytes: size.bytes), cost: size.cost,
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
