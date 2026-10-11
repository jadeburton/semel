// CacheTrimming.swift
// SemelCore
//
// The cache's size and its limit (B-148). An entry holds hashes, and its size is the bytes
// of the objects in the store it alone holds: no other entry, and not the input file
// system. The cache keeps a running total of those bytes, each object once, so that asking
// whether it is over its limit is one row, and trimming it reads rows and never the store.
//
// The limit is the home's, kept in `semel.engine.config` and handed to the engine by
// `semelserv` (`configuredCacheLimit`); when the total passes it, the trim at idle evicts
// entries in the order `CacheEvictionPolicy` gives until it is under, and the collector
// right after it gives their objects back. The order and the trim are `SemelCache`'s; what
// is here is what only the engine knows — when a settle ends, what the input file system
// holds, and what the cache's objects are.

import Foundation
import SemelCache
import SemelDatabaseModels
import SemelNodeKit

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

    /// The limit in force, and whether it is the default because the home set none.
    public func cacheLimit() -> (limit: ByteCount, isDefault: Bool) {
        guard let configured = configuredCacheLimit else {
            return (Self.defaultCacheLimit, true)
        }
        return (configured, false)
    }

    /// Takes the home's limit, or none, without trimming: what `semelserv` does when it
    /// starts, as the limit it read is the one the cache was last trimmed to, and the next
    /// idle trims to it if it is not.
    public func applyCacheLimit(_ limit: ByteCount?) {
        configuredCacheLimit = limit
    }

    /// Takes the home's limit and trims to it now, rather than at the next idle: whoever
    /// lowered it wants to see what that costs. The objects go with the next collection.
    /// Writing it to the home is the caller's: the engine keeps no file.
    @discardableResult
    public func setCacheLimit(_ limit: ByteCount) throws -> CacheTrim {
        applyCacheLimit(limit)
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

    /// Trims the cache to the limit in force, in `SemelCache`'s order.
    func trimCache() throws -> CacheTrim {
        try database.cacheEntry.trim(toLimit: cacheLimit().limit)
    }

    public func cacheReport() throws -> CacheReport {
        let account = try database.cacheEntry.account()
        let (limit, isDefault) = cacheLimit()
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
