// CacheStore.swift
// SemelCache
//
// Where entries are kept, as the cache sees it: by key, with the objects each one holds
// and their sizes, and a running total of those bytes (B-148). The engine's store keeps
// the rows in its graph database; a cache server's keeps the same rows in a database of its
// own. Both answer the same questions, so the eviction order and the trim are written once,
// here, over the protocol.

import Foundation
import SemelNodeKit

/// An object an entry holds in the object store, with its size there.
public struct CachedObject: Equatable, Hashable {
    public let hash:  DataObjectHash
    public let bytes: Int

    public init(hash: DataObjectHash, bytes: Int) {
        self.hash  = hash
        self.bytes = bytes
    }
}

/// The cache as a whole: the running total of what it holds, and the ordinals eviction
/// reads.
///
/// The ordinals count uses of the cache, not time: `settle` is stamped on every entry the
/// use in progress writes or reads, and closing a use that touched the cache moves it on
/// and records it as `lastUsingSettle`. "Not used by the last settle" is then `lastUse <
/// lastUsingSettle`, whatever the clock says. The engine closes one per settle; a store
/// with no settles closes them on whatever it counts uses in.
public struct CacheAccount: Codable, Equatable {
    /// Bytes of the objects the entries hold that nothing outside the cache does, each
    /// object once.
    public let bytes: Int
    public let settle: Int
    public let lastUsingSettle: Int

    public init(bytes: Int, settle: Int, lastUsingSettle: Int) {
        self.bytes           = bytes
        self.settle          = settle
        self.lastUsingSettle = lastUsingSettle
    }
}

/// An entry as eviction and `cache` see it: no content, and its size.
public struct CacheEntrySize: Equatable {
    public let hash:     String
    public let nodeType: String
    /// Milliseconds (`CacheCost`).
    public let cost:     Int
    public let lastUse:  Int
    /// The bytes of the objects this entry holds and nothing else does: no other entry,
    /// and nothing outside the cache. What evicting it alone would give back.
    public let bytes:    Int
    /// Its share of the objects it holds with other entries, none of which a node stands
    /// on: each such object's bytes divided among its holders, rounded up. Evicting the
    /// entry gives none of it back, but it leaves the others nearer to giving it all back,
    /// which is what lets two entries that share everything be evicted at all.
    public let sharedBytes: Int
    /// Whether something the store serves records this key as the one its outputs came
    /// from — a node of the engine's graph. Such an entry is never evicted.
    public let heldByNode: Bool

    public init(hash: String, nodeType: String, cost: Int, lastUse: Int, bytes: Int, sharedBytes: Int, heldByNode: Bool) {
        self.hash        = hash
        self.nodeType    = nodeType
        self.cost        = cost
        self.lastUse     = lastUse
        self.bytes       = bytes
        self.sharedBytes = sharedBytes
        self.heldByNode  = heldByNode
    }

    /// What eviction weighs the entry's cost against: what it alone holds and its share of
    /// what it holds with entries that may go too.
    public var weight: Int {
        bytes + sharedBytes
    }
}

/// A store of cache entries. The key is the entry's `cacheKey()`, named `hash` as the store
/// files it.
///
/// What a store keeps beside each entry is what the accounting needs and nothing about
/// the graph that built it: the node type the material names, the cost, the settle that
/// last used it, and the objects it holds with their sizes. Which objects those are is the
/// writer's to say, since only a writer that can read the object store can follow an
/// entry's values into the documents they name.
public protocol CacheStore {

    /// The stored bytes of the entry under `hash`, or nil when there is none. Bytes, not
    /// an entry: a row this Semel cannot decode is a miss to its reader, and something a
    /// listing or a debug print still wants to show.
    func content(hash: String) throws -> Data?

    /// Stores an entry whether or not its key is already taken, holding `objects`, stamped
    /// as used by the settle in progress. A key is a build, so a row already under it is the
    /// same build or one this Semel could not read; either way the one being written wins.
    func save(hash: String, nodeType: String, cost: Int, content: Data, objects: [CachedObject]) throws

    /// Stamps the entry as used by the settle in progress: a hit.
    func noteUse(hash: String) throws

    /// Removes the entry and its holds on its objects. Whether there was one.
    func delete(hash: String) throws -> Bool

    /// The running total and the settle ordinals.
    func account() throws -> CacheAccount

    /// Every entry with its size, read from the rows: nothing in the object store is opened.
    func sizes() throws -> [CacheEntrySize]

    /// The objects an entry holds, by hash, sorted.
    func objects(ofEntry hash: String) throws -> [DataObjectHash]
}

extension CacheStore {

    /// The entry under `key`, or nil when there is none or its bytes are not an entry this
    /// Semel reads — both are a miss.
    public func entry(forKey key: String) throws -> ProcessCacheEntry? {
        guard let content = try content(hash: key) else {
            return nil
        }
        return try? ProcessCacheEntry.decoded(from: content)
    }

    /// Stores `entry` under the key its material takes. The material rather than a key is
    /// what decides where it goes, so an entry is never filed under a key it does not
    /// account for.
    public func put(_ entry: ProcessCacheEntry, cost: Int, objects: [CachedObject]) throws {
        try save(hash: try entry.cacheKey(),
                 nodeType: entry.keyMaterial.nodeType,
                 cost: cost,
                 content: try entry.encoded(),
                 objects: objects)
    }
}
