// PopulationQueue.swift
// SemelCache
//
// What an engine has built and not yet written to its shared cache (B-153), waiting for the
// thread that writes it. Bounded, because the server may be slow or gone for as long as it
// likes and the engine's memory must not follow: when the queue is full the oldest item
// goes, which costs some other machine one build and this one nothing.

import Foundation
import SemelNodeKit

/// One entry to write: what `putEntry` takes, and the objects to put before it. The objects'
/// bytes are not held here — they are in the engine's object store, and read from there
/// when the item is written — so an item is the entry's own bytes and a list of hashes.
public struct PopulationItem: Equatable, Sendable {
    public let key: CacheKey
    /// Milliseconds (`CacheCost`).
    public let cost: Int
    public let objects: [CachedObject]
    public let content: Data

    public init(key: CacheKey, cost: Int, objects: [CachedObject], content: Data) {
        self.key     = key
        self.cost    = cost
        self.objects = objects
        self.content = content
    }
}

/// The items in the order they were built, oldest first, held to a count and to the bytes of
/// their entries.
///
/// Not thread-safe: `SharedCache` holds it under its lock.
public struct PopulationQueue: Equatable, Sendable {

    /// How much the queue may hold.
    public struct Capacity: Equatable, Sendable {
        public let items: Int
        public let bytes: Int

        public init(items: Int, bytes: Int) {
            self.items = max(1, items)
            self.bytes = max(0, bytes)
        }

        /// A thousand entries, or 64 MiB of them. An entry is a few kilobytes of JSON, so
        /// the count binds first in an ordinary build, and a thousand is more than a cold
        /// build of a large project writes faster than a LAN takes them; the bytes bind for
        /// a product builder's entries, which can run to megabytes each.
        public static let standard = Capacity(items: 1_000, bytes: 64 * ByteCount.mebibyte)
    }

    public let capacity: Capacity
    public private(set) var items: [PopulationItem] = []
    public private(set) var bytes = 0

    public init(capacity: Capacity) {
        self.capacity = capacity
    }

    public var count: Int {
        items.count
    }

    public var isEmpty: Bool {
        items.isEmpty
    }

    /// Adds `item` at the back and drops from the front until the queue is within its
    /// capacity again. How many it dropped — the item itself, when it alone is over the
    /// bytes.
    @discardableResult
    public mutating func append(_ item: PopulationItem) -> Int {
        items.append(item)
        bytes += item.content.count
        var dropped = 0
        while !items.isEmpty, items.count > capacity.items || bytes > capacity.bytes {
            bytes -= items.removeFirst().content.count
            dropped += 1
        }
        return dropped
    }

    /// The oldest item, taken off the queue.
    public mutating func removeFirst() -> PopulationItem? {
        guard !items.isEmpty else {
            return nil
        }
        let item = items.removeFirst()
        bytes -= item.content.count
        return item
    }

    /// Empties the queue. How many items it held.
    @discardableResult
    public mutating func removeAll() -> Int {
        let removed = items.count
        items.removeAll()
        bytes = 0
        return removed
    }
}
