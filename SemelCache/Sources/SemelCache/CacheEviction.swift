// CacheEviction.swift
// SemelCache
//
// The cache's limit and what goes first when it is over (B-148). A trim reads the store's
// rows — the running total and every entry's size — and never the object store, and
// evicts in the order `CacheEvictionPolicy` gives until the total is under the limit. The
// objects an eviction gives back are the object store's to collect afterwards.

import Foundation
import SemelNodeKit

/// What one trim did: the entries it evicted, each with the bytes its eviction gave back,
/// and the total before and after against the limit.
public struct CacheTrim: Equatable {
    public struct Eviction: Equatable {
        public let entry: CacheEntrySize
        /// Measured, not the size the entry was ordered by: evicting one entry can leave
        /// another the last holder of an object they shared, and that object then goes
        /// with the second.
        public let freed: ByteCount

        public init(entry: CacheEntrySize, freed: ByteCount) {
            self.entry = entry
            self.freed = freed
        }
    }

    public let evictions: [Eviction]
    public let bytesBefore: ByteCount
    public let bytesAfter: ByteCount
    public let limit: ByteCount

    public init(evictions: [Eviction], bytesBefore: ByteCount, bytesAfter: ByteCount, limit: ByteCount) {
        self.evictions   = evictions
        self.bytesBefore = bytesBefore
        self.bytesAfter  = bytesAfter
        self.limit       = limit
    }

    public var freed: ByteCount {
        ByteCount(bytes: bytesBefore.bytes - bytesAfter.bytes)
    }

    /// How many entries of each node type went, by type name.
    public var evictedByType: [(nodeType: String, count: Int)] {
        Dictionary(grouping: evictions, by: \.entry.nodeType)
            .map { (nodeType: $0.key, count: $0.value.count) }
            .sorted { ($1.count, $0.nodeType) < ($0.count, $1.nodeType) }
    }
}

// MARK: - Which entries go first

/// The order a trim evicts in. A resource policy, not part of the function model: which
/// entries are kept changes what a later settle recomputes, never what it computes.
///
/// - An entry a node of the graph records as the key its outputs came from is never
///   evicted. Its objects are on that node's ports, so evicting it would give back nothing
///   the collector could take, and the next time the node's inputs come back to these
///   values — an undo, a `reset` — it would cost the whole build.
/// - Entries the last settle wrote or read go after every entry it did not: they are
///   the working set of what was just built.
/// - Within each, the lowest recorded cost per byte goes first. A trim has bytes to give
///   back and builds to lose, and the cost is what each entry would take to build again,
///   so evicting the cheapest builds per byte keeps the most build time in the bytes
///   that stay: a module's compile kept over a linker's output ten times its size that
///   took a tenth of the time. Order by last use alone would evict an expensive compile
///   because another project was built since, which is the case B-147 left open.
/// - The bytes are the entry's weight: what it alone holds, and its share of each object
///   it holds with other entries no node stands on. A pair that holds one object between
///   them weighs half of it each, so two builds that produced the same bytes can be
///   evicted, the first giving back nothing and the second the object. An entry of no
///   weight — its objects held outside the cache, or shared with an entry a node stands
///   on — gives nothing back, ever, and is never evicted.
/// - Ties: the older use first, then the key, so the order is a function of the rows.
///
/// The cost is a duration, measured on the machine under whatever load it had; it orders
/// eviction and nothing else, which is the one decision it is allowed to take.
public enum CacheEvictionPolicy {

    public static func order(_ sizes: [CacheEntrySize], lastUsingSettle: Int) -> [CacheEntrySize] {
        sizes.filter { !$0.heldByNode }.sorted { precedes($0, $1, lastUsingSettle: lastUsingSettle) }
    }

    /// Whether `first` is evicted before `second`.
    public static func precedes(_ first: CacheEntrySize, _ second: CacheEntrySize, lastUsingSettle: Int) -> Bool {
        let firstRecent  = first.lastUse  >= lastUsingSettle
        let secondRecent = second.lastUse >= lastUsingSettle
        guard firstRecent == secondRecent else {
            return !firstRecent
        }
        let firstEmpty  = first.weight  == 0
        let secondEmpty = second.weight == 0
        guard firstEmpty == secondEmpty else {
            return !firstEmpty
        }
        // Cost per byte compared without dividing: first.cost / first.weight against
        // second.cost / second.weight. A cost in milliseconds times a size in bytes stays
        // far inside 64 bits for any entry a disk can hold.
        let firstScaled  = first.cost  * max(second.weight, 1)
        let secondScaled = second.cost * max(first.weight, 1)
        guard firstScaled == secondScaled else {
            return firstScaled < secondScaled
        }
        guard first.lastUse == second.lastUse else {
            return first.lastUse < second.lastUse
        }
        return first.hash < second.hash
    }
}

// MARK: - The trim

extension CacheStore {

    /// Evicts until the running total is at or under `limit`, or nothing evictable is
    /// left. A pass orders the entries once and evicts down the order, passing over what
    /// weighs nothing; the next pass weighs what is left again, since an eviction that gave
    /// back nothing left another entry the last holder of what the two shared.
    public func trim(toLimit limit: ByteCount) throws -> CacheTrim {
        let before = try account().bytes
        var current = before
        var evictions: [CacheTrim.Eviction] = []
        while current > limit.bytes {
            let lastUsingSettle = try account().lastUsingSettle
            let order = CacheEvictionPolicy.order(try sizes(), lastUsingSettle: lastUsingSettle)
            var evictedThisPass = false
            for candidate in order where candidate.weight > 0 && current > limit.bytes {
                guard try delete(hash: candidate.hash) else {
                    continue
                }
                let after = try account().bytes
                evictions.append(CacheTrim.Eviction(entry: candidate, freed: ByteCount(bytes: current - after)))
                current = after
                evictedThisPass = true
            }
            guard evictedThisPass else {
                break
            }
        }
        return CacheTrim(evictions: evictions, bytesBefore: ByteCount(bytes: before),
                         bytesAfter: ByteCount(bytes: current), limit: limit)
    }
}
