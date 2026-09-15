//
//  TreeManifest.swift
//  SemelNodeKit
//
//  A port carries one value. A tool that writes a directory of results — an asset
//  catalog compiler's `Assets.car` and one PNG per icon size, a string catalog compiler's
//  one `.lproj` per language — decides its own file set, which no formula can name in
//  advance. A tree is how one port carries N files: a manifest of relative paths, each
//  with the content hash and the mode, interned like any value. Nothing about wires,
//  caching or the database changes; what changes is that a node can say "here are N
//  files" and a product can publish every one of them.

/// One file of a tree.
public struct TreeManifestEntry: Codable, Equatable {
    /// Relative to the tree's root, `/`-separated: `en.lproj/Localizable.strings`.
    public let path: String
    /// SHA-256 hex digest of the content in `DataObjectStore`.
    public let hash: String
    /// POSIX permission bits, so an executable inside a tree stays one.
    public let mode: UInt16

    public init(path: String, hash: String, mode: UInt16) {
        self.path = path
        self.hash = hash
        self.mode = mode
    }
}

public struct TreeManifest: PolySerializable, Equatable {
    public static let kind: UInt = 27

    /// Sorted by path, whatever order they were collected in: a manifest is a value, and
    /// two trees with the same files must intern to the same hash.
    public let entries: [TreeManifestEntry]

    public init(entries: [TreeManifestEntry]) {
        self.entries = entries.sorted { $0.path < $1.path }
    }

    public func entry(at path: String) -> TreeManifestEntry? {
        entries.first { $0.path == path }
    }
}
