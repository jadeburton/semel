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

    /// For a subfolder that is a symbolic link pushed as one, what the link holds (B-77).
    /// Such a folder holds what the link names, as a push always stored it, so a walk that
    /// reads files goes on descending into it; a walk that builds a tree does not, and
    /// places the link instead — which it has to know before it descends, so it is here and
    /// not on a port of the subfolder. A file that is a link says so on its `fileMetadata`,
    /// beside its bytes, where what reads files already looks. Nil for anything else, and
    /// then not encoded, so a manifest without links is the value it always was.
    public let symbolicLinkTarget: String?

    public init(name: String, isFolder: Bool, isPinned: Bool, symbolicLinkTarget: String? = nil) {
        self.name = name
        self.isFolder = isFolder
        self.isPinned = isPinned
        self.symbolicLinkTarget = symbolicLinkTarget
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
