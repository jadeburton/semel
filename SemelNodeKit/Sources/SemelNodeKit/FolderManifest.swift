// FolderManifest.swift
// SemelNodeKit
//
// What a folder tells the nodes downstream of it.
//
/// One immediate child of a folder. A manifest is deliberately non-recursive,
/// as this will not scale to massive file system trees.
///
/// Names and pinned state, and no content: a consumer wired to a manifest is asking which
/// children a folder has, and a manifest that moved when a child's bytes moved would
/// re-run every one of them on every edit. What a folder's content hashes to is a separate
/// question and is answered on a separate port — see `FolderContentRoot`.
public struct FolderManifestEntry: Codable {
    public let name: String
    public let isFolder: Bool

    // A pinned object is one that was explicitly added by the user, not one that exists only as a product of the graph
    // itself and is only held alive by wires from the graph. If an object is not pinned and not held alive by wires,
    // then it stops existing.
    public let isPinned: Bool

    public init(name: String, isFolder: Bool, isPinned: Bool) {
        self.name = name
        self.isFolder = isFolder
        self.isPinned = isPinned
    }
}

public struct FolderManifest: PolySerializable {
    public static let kind: UInt = 4

    public let baseFolderPath: String
    public let entries: [FolderManifestEntry]

    public init(baseFolderPath: String, entries: [FolderManifestEntry]) {
        self.baseFolderPath = baseFolderPath
        self.entries = entries
    }
}

/// The roots of the two virtual file systems. Every path in the graph begins with one.
public enum FileSystemName {
    public static let input  = "input:"
    public static let output = "output:"
}
