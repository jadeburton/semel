// FolderSubtreeManifest.swift
// SemelNodeKit
//
// What a folder holds at every depth, by name: the third value a folder publishes, beside
// its manifest (its own children) and its content root (what everything below it hashes
// to). A consumer that has to know a whole tree — a converter looking for a target's
// resources, a builder expanding `**` — asks for it once and has it on the next pass,
// where a walk over manifests asks for one level per pass (B-135).
//

import Foundation
import SemelDatabaseModels

/// One child of a folder, as its folder's subtree manifest lists it: the facts a
/// `FolderManifestEntry` carries, and for a subfolder the hash of that subfolder's own
/// subtree manifest.
///
/// By reference rather than nested. A folder's document is its own children and nothing
/// more, so a fold costs one document per folder whatever lies below it — the cost the
/// content root has — and a change of names deep down refolds each ancestor once, over its
/// children, never over its subtree. The hash is what makes the document stand for the
/// whole tree: a name that changes anywhere below moves the hash of every document above
/// it, exactly as a content root moves, and a reader follows the hashes as far down as it
/// means to go.
public struct FolderSubtreeEntry: Codable, Equatable {
    public let name: String
    public let isFolder: Bool
    /// Held by the user rather than by a wire (see `FolderManifestEntry.isPinned`). An
    /// unpinned entry is a ghost — deleted, or never pushed — and a reader does not
    /// descend into one.
    public let isPinned: Bool
    /// For a subfolder pushed as a symbolic link, what the link holds (B-77), as its
    /// parent's manifest says it. Nil otherwise, and then not encoded.
    public let symbolicLinkTarget: String?
    /// For a subfolder, the hash of its own subtree manifest's document; nil for a file,
    /// and for a subfolder that has published none.
    public let subtree: DataObjectHash?

    public init(name: String, isFolder: Bool, isPinned: Bool, symbolicLinkTarget: String? = nil,
                subtree: DataObjectHash? = nil) {
        self.name = name
        self.isFolder = isFolder
        self.isPinned = isPinned
        self.symbolicLinkTarget = symbolicLinkTarget
        self.subtree = subtree
    }

    /// The same child as its folder's manifest lists it.
    public var manifestEntry: FolderManifestEntry {
        FolderManifestEntry(name: name, isFolder: isFolder, isPinned: isPinned, symbolicLinkTarget: symbolicLinkTarget)
    }
}

/// What a `Folder` publishes on its `subtreeManifest` port: the names, kinds and pinned
/// state of everything below it, at every depth, and no content.
///
/// No content, and that is the point of having it beside the content root: a consumer
/// asking what a tree holds is woken when a name below changes, not when a file below is
/// edited. No path either: the document is its children, so the same tree at two paths is
/// one document, as its content root is one hash. A reader knows the path it asked for —
/// the key of the wire it asked on — and `folderManifests(at:)` puts the two together.
public struct FolderSubtreeManifest: PolySerializable, Equatable {
    public static let kind: UInt = 43

    /// Sorted by name, as UTF-8 bytes: the order the children are read in is the database's,
    /// and a value that moved with it would wake every consumer for nothing.
    public let entries: [FolderSubtreeEntry]

    public init(entries: [FolderSubtreeEntry]) {
        self.entries = entries.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
    }

    /// Why a subtree could not be read back.
    public enum ReadError: Error, CustomStringConvertible {
        /// A subfolder's document names a hash the store does not hold, or one that is not
        /// a subtree manifest.
        case unreadableSubtree(folder: String, hash: DataObjectHash)

        public var description: String {
            switch self {
            case .unreadableSubtree(let folder, let hash):
                return "the subtree manifest of \(folder) (\(hash)) cannot be read"
            }
        }
    }

    /// The manifest of the folder at `path` that published this tree, and of every pinned
    /// subfolder below it that `include` accepts — and every one below those, at every
    /// depth — keyed by full path: the shape a walk over manifests arrives at, in one read.
    ///
    /// `include` is asked about a subfolder by its full path before it is descended into, so
    /// a stop rule — a catalog compiled whole, a hidden folder, a `.lproj` a package search
    /// never looks into — costs nothing below it: its document is never read. A subfolder
    /// that is a symbolic link is descended into as any folder unless `intoSymbolicLinks`
    /// says not to, as a node building a tree says (`FolderTreeWalk.symbolicLinkFolders`).
    public func folderManifests(at path: String, intoSymbolicLinks: Bool = true,
                                include: (String) -> Bool = { _ in true }) throws -> [String: FolderManifest] {
        var result: [String: FolderManifest] = [:]
        var pending: [(path: String, tree: FolderSubtreeManifest)] = [(path, self)]
        while let (folder, tree) = pending.popLast() {
            result[folder] = FolderManifest(baseFolderPath: folder, entries: tree.entries.map(\.manifestEntry))
            for entry in tree.entries where entry.isFolder && entry.isPinned {
                guard intoSymbolicLinks || entry.symbolicLinkTarget == nil else {
                    continue
                }
                let subfolder = (Path(folder) / entry.name).string
                guard include(subfolder) else {
                    continue
                }
                pending.append((subfolder, try Self.read(entry.subtree, of: subfolder)))
            }
        }
        return result
    }

    /// The subtree manifest of the folder at `path`, folded from `listings` — what each
    /// folder holds, by full path, one that is not listed holding nothing — with every
    /// subfolder's own subtree manifest interned as a `Folder` interns it. The shape a push
    /// of those listings would publish, for a node's tests to hand it as the engine does.
    public static func folding(at path: String, listings: [String: [FolderManifestEntry]]) throws -> FolderSubtreeManifest {
        let entries = try (listings[path] ?? []).map { entry -> FolderSubtreeEntry in
            guard entry.isFolder else {
                return FolderSubtreeEntry(name: entry.name, isFolder: false, isPinned: entry.isPinned)
            }
            let subtree = try folding(at: (Path(path) / entry.name).string, listings: listings)
            return FolderSubtreeEntry(name: entry.name, isFolder: true, isPinned: entry.isPinned,
                                      symbolicLinkTarget: entry.symbolicLinkTarget, subtree: try subtree.toJSON().intern())
        }
        return FolderSubtreeManifest(entries: entries)
    }

    /// The subtree manifest a subfolder's entry names; an empty one where it names none,
    /// which is what a folder that has published nothing yet holds.
    static func read(_ hash: DataObjectHash?, of folder: String) throws -> FolderSubtreeManifest {
        guard let hash, !hash.isEmpty else {
            return FolderSubtreeManifest(entries: [])
        }
        guard let json = try? hash.resolveAsString(),
              let tree: FolderSubtreeManifest = try? TypeRegistry.decodeAndCast(encodedJSON: json) else {
            throw ReadError.unreadableSubtree(folder: folder, hash: hash)
        }
        return tree
    }
}
