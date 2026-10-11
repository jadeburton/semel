// CacheKey.swift
// SemelCache
//
// The key an entry is filed under, as a value of its own wherever it leaves the process
// that computed it: in a request to a cache server, in a reply listing the cache, and where
// a person types one. Inside the engine the key is the hex its material hashes to; here it
// is the same hex under a type, so a key and any other string cannot be passed for each
// other across a process.

import Foundation

/// A cache key: the SHA-256 of an entry's `CacheKeyMaterial.canonicalText()`, as hex.
///
/// Encoded as that hex alone, a bare JSON string, so a message carrying a key reads as the
/// key and the type costs nothing on the wire.
///
/// Two ways in, because two kinds of source hand one over. A key computed from material,
/// or read back from a store's row, is whatever the store holds and is taken as it is: a
/// row a hand edit damaged is still a row a listing must be able to name, and a lookup of
/// a key nothing holds is a miss. A key a person typed is checked where it is typed
/// (`init?(parsing:)`), so a mistyped one is refused there by name rather than travelling
/// to a server to miss.
public struct CacheKey: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {

    /// The key's hex, as the store files the entry.
    public let hash: String

    public init(hash: String) {
        self.hash = hash
    }

    /// A key as a person writes one: the 64 lowercase hex digits of a SHA-256. A cache key
    /// is always that long, since the text it is the hash of is always longer than a digest
    /// (`Sha256.hash` files only something shorter under its own bytes).
    public init?(parsing text: String) {
        guard text.utf8.count == 64,
              text.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            return nil
        }
        self.init(hash: text)
    }

    public init(from decoder: any Decoder) throws {
        hash = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hash)
    }

    public static func < (lhs: CacheKey, rhs: CacheKey) -> Bool {
        lhs.hash < rhs.hash
    }

    public var description: String {
        hash
    }
}

extension CacheKeyMaterial {

    /// The cache key, typed: what a key computed here is called once it leaves the process.
    public func key() throws -> CacheKey {
        CacheKey(hash: try cacheKey())
    }
}

extension ProcessCacheEntry {

    /// The key the entry is stored under, typed.
    public func key() throws -> CacheKey {
        try keyMaterial.key()
    }
}
