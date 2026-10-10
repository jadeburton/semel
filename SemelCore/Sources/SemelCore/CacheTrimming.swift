// CacheTrimming.swift
// SemelCore
//
// The cache's size and its limit (B-148). An entry holds hashes, and its size is the bytes
// of the objects in the store it alone holds: no other entry, and not the input file
// system. The cache keeps a running total of those bytes, each object once, so that asking
// whether it is over its limit is one row, and trimming it reads rows and never the store.
//
// The limit is the home's, stored in the graph's database; when the total passes it, the
// trim at idle evicts entries in the order `CacheEvictionPolicy` gives until it is under,
// and the collector right after it gives their objects back.

import Foundation
import SemelDatabaseModels
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
    }

    public let evictions: [Eviction]
    public let bytesBefore: ByteCount
    public let bytesAfter: ByteCount
    public let limit: ByteCount

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

/// The cache as `cache` shows it: every entry with its size, the total and the limit.
public struct CacheReport {
    public let entries: [CacheEntrySize]
    public let bytes: ByteCount
    public let limit: ByteCount
    /// Whether no limit was set for this home, so the engine's default applies.
    public let limitIsDefault: Bool
    /// The ordinal of the last settle that used an entry: an entry whose `lastUse` is it
    /// was used by that settle.
    public let lastUsingSettle: Int
    public let lastTrim: CacheTrim?
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
///   weight — its objects held by the input file system, or shared with an entry a node
///   stands on — gives nothing back, ever, and is never evicted.
/// - Ties: the older use first, then the key, so the order is a function of the rows.
///
/// The cost is a duration, measured on the machine under whatever load it had; it orders
/// eviction and nothing else, which is the one decision it is allowed to take.
enum CacheEvictionPolicy {

    static func order(_ sizes: [CacheEntrySize], lastUsingSettle: Int) -> [CacheEntrySize] {
        sizes.filter { !$0.heldByNode }.sorted { precedes($0, $1, lastUsingSettle: lastUsingSettle) }
    }

    /// Whether `first` is evicted before `second`.
    static func precedes(_ first: CacheEntrySize, _ second: CacheEntrySize, lastUsingSettle: Int) -> Bool {
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

// MARK: - The engine's side

extension BuildEngine {

    /// The limit of a home that never set one. Liberal on purpose: NetNewsWire's Mac app,
    /// IceCubes and CodeEdit built in one home hold well under it (FUTURE.md, B-148), so a
    /// developer meets eviction only once the home has outgrown several projects of that
    /// size.
    public static let defaultCacheLimit = ByteCount.gibibytes(10)

    /// The node kinds whose ports are the input file system: what a push holds is not the
    /// cache's to count.
    static var inputFileSystemKinds: [UInt] {
        [StaticFile.kind]
    }

    /// The objects a cached build holds, as the collector would follow them from its
    /// outputs, with their sizes in the store. An object the store does not have — one a
    /// collection took under an entry nothing referred to before this one — is no bytes.
    static func heldObjects(outputValues: [String: NodeValue], in store: DataObjectStore) -> [CachedObject] {
        var held = Set(objects(inOutputValues: outputValues))
        held.remove("")
        markDocuments(reaching: &held, in: store)
        return held.sorted().map { CachedObject(hash: $0, bytes: store.size(hash: $0) ?? 0) }
    }

    public func cacheLimit() throws -> (limit: ByteCount, isDefault: Bool) {
        guard let bytes = try database.cacheEntry.account().limitBytes else {
            return (Self.defaultCacheLimit, true)
        }
        return (ByteCount(bytes: bytes), false)
    }

    /// Stores the home's limit and trims to it now, rather than at the next idle: whoever
    /// lowered it wants to see what that costs. The objects go with the next collection.
    @discardableResult
    public func setCacheLimit(_ limit: ByteCount) throws -> CacheTrim {
        try database.cacheEntry.setLimit(bytes: limit.bytes)
        let trim = try trimCache()
        if !trim.evictions.isEmpty {
            lastCacheTrim = trim
        }
        return trim
    }

    /// The trim the loop runs at idle: the settle that just ended is closed for the cache,
    /// what the input file system holds is recounted, and the cache is trimmed to its
    /// limit. Says what it evicted, and returns whether it evicted anything, so that the
    /// collection after it gives the bytes back. Best effort, like the collector.
    func trimCacheAtIdle() -> Bool {
        let trim = FatalErrors.attempt { () -> CacheTrim in
            try database.cacheEntry.closeSettle()
            try database.cacheEntry.refreshInputHolding(inputKinds: Self.inputFileSystemKinds)
            return try trimCache()
        }
        guard let trim, !trim.evictions.isEmpty else {
            return false
        }
        lastCacheTrim = trim
        Self.notice(Self.describe(trim))
        return true
    }

    /// The line a trim is reported in: what went, by type, and where the cache stands.
    static func describe(_ trim: CacheTrim) -> String {
        let count = trim.evictions.count
        let types = trim.evictedByType.map { "\($0.nodeType) \($0.count)" }.joined(separator: ", ")
        var line = "The cache was over its limit of \(trim.limit): evicted \(count) entr\(count == 1 ? "y" : "ies") "
                 + "(\(trim.freed)) — \(types); it holds \(trim.bytesAfter)."
        if trim.bytesAfter > trim.limit {
            line += " The rest is held by entries the graph's nodes hold values from, which are not evicted."
        }
        return line
    }

    /// Evicts until the running total is at or under the limit, or nothing evictable is
    /// left. A pass orders the entries once and evicts down the order, passing over what
    /// weighs nothing; the next pass weighs what is left again, since an eviction that gave
    /// back nothing left another entry the last holder of what the two shared.
    func trimCache() throws -> CacheTrim {
        let limit = try cacheLimit().limit
        let before = try database.cacheEntry.account().bytes
        var current = before
        var evictions: [CacheTrim.Eviction] = []
        while current > limit.bytes {
            let account = try database.cacheEntry.account()
            let order = CacheEvictionPolicy.order(try database.cacheEntry.sizes(), lastUsingSettle: account.lastUsingSettle)
            var evictedThisPass = false
            for candidate in order where candidate.weight > 0 && current > limit.bytes {
                guard try database.cacheEntry.delete(hash: candidate.hash) else {
                    continue
                }
                let after = try database.cacheEntry.account().bytes
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

    public func cacheReport() throws -> CacheReport {
        let account = try database.cacheEntry.account()
        let (limit, isDefault) = try cacheLimit()
        return CacheReport(entries: try database.cacheEntry.sizes(),
                           bytes: ByteCount(bytes: account.bytes),
                           limit: limit,
                           limitIsDefault: isDefault,
                           lastUsingSettle: account.lastUsingSettle,
                           lastTrim: lastCacheTrim)
    }

    /// The total recounted from the entries themselves rather than kept: each entry's
    /// content decoded, its objects followed through the store and sized, every object
    /// once, and what the input file system holds left out. What the running total must
    /// equal; reads the store, so it is for a test or a check, not for a trim.
    func recountedCacheBytes() throws -> ByteCount {
        var held = Set<DataObjectHash>()
        for content in try database.cacheEntry.selectAllContent() {
            held.formUnion(Self.objects(inCacheContent: content))
        }
        held.remove("")
        let store = DataObjectStore.shared
        Self.markDocuments(reaching: &held, in: store)
        held.subtract(try database.outputPort.selectHashes(ofNodeKinds: Self.inputFileSystemKinds))
        return ByteCount(bytes: held.sorted().reduce(0) { $0 + (store.size(hash: $1) ?? 0) })
    }
}
