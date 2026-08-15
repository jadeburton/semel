// FolderManifest.swift
// SemelNodeKit
//
// What a folder tells the nodes downstream of it, and the names of the two file systems.
//
// Both were declared inside Folder.swift, which reads naturally until you notice that the
// manifest is a *wire data format* every node function decodes, and that "input:" and
// "output:" are shared vocabulary rather than one node type's internals. Neither can move
// to a toolchain package, and neither should oblige it to depend on the engine.

/// One immediate child of a folder. A manifest is deliberately non-recursive.
public struct FolderManifestEntry: Codable {
    public let name: String
    public let isFolder: Bool
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
