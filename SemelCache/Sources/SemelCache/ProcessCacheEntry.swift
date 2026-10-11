// ProcessCacheEntry.swift
// SemelCache
//
// One cached build as it is stored, and what it cost. The encoding here is the bytes a
// store keeps, so it is pinned by a fixture: an engine and a server reading one entry have
// to agree on it byte for byte.

import Foundation
import SemelNodeKit

/// A cached `ProcessOutput` as stored, with the material its key was taken of. A field
/// added here is non-optional, so an entry written before it fails to decode and misses,
/// rather than decoding short with a default and hitting wrongly.
///
/// The demanded specs are stored as a table, each distinct spec node once (B-121): spelled
/// out as trees, one entry of a product builder's held the settings chain thousands of
/// times over and ran to 15 MB. The table is the one the run's output was applied from,
/// and a hit applies it again as it stands.
///
/// An entry holds hashes, not bytes: the objects its values name live in the object store,
/// and a store that keeps entries keeps, beside each, which of those objects it holds
/// (`CacheStore.objects(ofEntry:)`).
public struct ProcessCacheEntry: Codable {
    public let outputValues: [String: NodeValue]
    public let specTable: GraphSpecTable
    public let keyMaterial: CacheKeyMaterial

    public init(outputValues: [String: NodeValue], specTable: GraphSpecTable, keyMaterial: CacheKeyMaterial) {
        self.outputValues = outputValues
        self.specTable    = specTable
        self.keyMaterial  = keyMaterial
    }

    /// The key the entry is stored under: the hash of its own material, so an entry can
    /// never be filed under a key nothing in it accounts for (B-13).
    public func cacheKey() throws -> String {
        try keyMaterial.cacheKey()
    }

    /// The bytes a store keeps: JSON with sorted keys, so the same entry is the same bytes
    /// in every process that writes it.
    public func encoded() throws -> Data {
        Data(try toJSON().utf8)
    }

    /// The entry the bytes hold. Throws for bytes of another shape — an entry an older
    /// Semel wrote, a damaged row — which the reader treats as a miss.
    public static func decoded(from content: Data) throws -> ProcessCacheEntry {
        try JSONDecoder().decode(ProcessCacheEntry.self, from: content)
    }
}

/// What an entry cost to build, as it is recorded beside it: whole milliseconds of the
/// run. It decides no value — an entry that existed only when a run was slow enough would
/// make a later build depend on the machine's load. It weighs which entry goes first when a
/// cache is over its limit (`CacheEvictionPolicy`), and what a remote cache will weigh a
/// fetch against; both are questions about resources, not about what a build computes.
public enum CacheCost {

    /// The cost recorded for a run that took `duration` seconds.
    public static func milliseconds(of duration: TimeInterval) -> Int {
        Int(duration * 1000.0)
    }
}
