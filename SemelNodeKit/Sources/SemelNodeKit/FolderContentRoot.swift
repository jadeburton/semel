// FolderContentRoot.swift
// SemelNodeKit
//
// What a folder's content hashes to, as against its manifest, which is what its children
// are called. A folder publishes the two on separate ports for the reason the split exists:
// a consumer asking which files are in a folder must not re-run because one of them was
// edited.
//

import Foundation
import SemelDatabaseModels

/// What one child contributes to its folder's content root.
///
/// Read by case. Every reason a child has no content of its own is a case on the port the
/// content would have come from, and the fold keeps them apart for the same reason: a
/// folder a file was taken out of and a folder that never held it are not the same folder,
/// and a consumer comparing two roots asks which it is rather than matching a sentence.
public enum FolderChildContent: Equatable {
    /// The child's own content, named by its hash: a subfolder's content root — which is
    /// folded the same way, so the fold reaches the whole subtree.
    case hash(DataObjectHash)
    /// A file's bytes, named by their hash, and the mode it was pushed with (B-132). The
    /// mode is on the line because a tree carries it (`TreeManifest`): a file made
    /// executable is a different tree to everything built from it, so a root that did not
    /// move with it would call two trees one — and a client comparing roots to decide what
    /// to push would never send the change.
    case file(hash: DataObjectHash, mode: UInt16)
    /// Nothing has produced content for this name: a source nobody pushed, or a child that
    /// has not run.
    case notProduced
    /// A source that was pushed and then taken back out.
    case deleted
    /// The child is waiting for a value, or it failed. Not reachable for the kinds the fold
    /// reads, whose ports hold no such state, and spelled out rather than folded into
    /// `notFolded` so that a reconciler is never told a failure is a structural gap.
    case failed
    /// A symbolic link, by its target as it holds it. The target and never the bytes it
    /// names: those are folded where they are, and a link is equal to another link only
    /// when both say the same thing.
    case symbolicLinkTarget(String)
    /// The fold does not reach this child's content, and the root does not claim to.
    ///
    /// A product is the case: its bytes arrive on an input wire rather than on a port of
    /// its own. The obstacle is not the extra query — that is one more join in the shape
    /// `selectChildPorts` already has — but invalidation. Nothing notifies a folder when a
    /// product below it changes: `notifyParentOfChildContentChange` is called by
    /// `StaticFile` and by `Folder`, and by nothing on the path that writes an
    /// `OutputFile`'s value. Folding a product's hash in would therefore give an `output:`
    /// folder a root that moves without the folder being rebuilt — a root that lies, which
    /// is strictly worse than one that says it does not know.
    case notFolded
}

extension FolderChildContent {
    public init(_ value: NodeValue) {
        switch value {
        case .value(let hash):
            self = .hash(hash)
        case .noValue(let reason):
            switch reason {
            case .initializing, .inputNotProduced: self = .notProduced
            case .deleted:                         self = .deleted
            case .pending, .inputInError, .error:  self = .failed
            }
        }
    }

    /// What this child writes into the fold.
    ///
    /// Spelled out rather than derived from the case name or from a synthesized `Codable`
    /// encoding. A root is meant to be recorded and compared across releases — B-06 locks a
    /// vendored dependency by one — so every byte of the document it hashes has to be a
    /// decision somebody made, not a name a refactor may rename or a key a compiler chose.
    var token: String {
        switch self {
        case .hash(let hash): return "hash \(hash)"
        // Octal, as a mode is written everywhere else a person reads one.
        case .file(let hash, let mode):
            return "hash \(hash) mode \(String(mode, radix: 8))"
        case .notProduced:    return "not-produced"
        case .deleted:        return "deleted"
        case .failed:         return "failed"
        case .notFolded:      return "not-folded"
        // Framed by its length as a name is, so a tab or a newline in a target changes
        // the root rather than the shape of the document.
        case .symbolicLinkTarget(let target):
            return "target \(target.utf8.count) \(target)"
        }
    }
}

/// What kind of child a line describes.
///
/// On the line because a hash does not say what it is a hash of. A file's bytes and a
/// folder's document are named out of one content-addressed store, so without the kind a
/// file whose contents happen to be an empty folder's document contributes the same line an
/// empty folder of that name would — and a lock satisfied by replacing a directory with a
/// file is not a lock. Git puts the mode in a tree entry for this reason.
public enum FolderChildKind: String {
    case file
    case folder
    /// Anything else a folder holds; the only such kind is a product (`OutputFile`).
    case other
    /// A symbolic link that stays inside its folder, pushed as the link it is (B-77): in
    /// the graph a file whose metadata names a target, or a folder whose `symbolicLink` port
    /// does, holding what the link names as a push always stored it. Its own kind, for the
    /// reason the kind is on the line at all: a link and a copy of what it names are not the
    /// same tree.
    case link
}

extension FolderChildKind {
    /// The order the fold puts kinds in when two children share a name. Stated as a rank
    /// rather than taken from the case name, for the reason `FolderChildContent.token` is
    /// stated: a recorded root must not move because somebody renamed a case.
    var sortRank: Int {
        switch self {
        case .file:   return 0
        case .folder: return 1
        case .other:  return 2
        case .link:   return 3
        }
    }
}

/// The document a folder's content root is the hash of.
///
/// A Merkle root is only as portable as the bytes underneath it, so the fold is a stated
/// text format rather than whatever an encoder happens to emit: a tagged first line, then
/// one line per child — its kind, what it holds, and its name. A subfolder's line carries
/// that subfolder's own root, which is how one hash comes to identify a whole tree.
///
/// The order is a total one, by the child's name as UTF-8 bytes and then by kind, so the
/// document is a function of what the folder holds and never of the order rows came back in.
///
/// The name is last on its line and preceded by its length in bytes, so the framing holds
/// whatever a name contains — a tab or a newline in a file name changes the root rather
/// than the shape of the document, which is the difference between two trees hashing apart
/// and two different trees hashing alike.
///
/// The root is *not* qualified by the folder's own path: the document says what is in the
/// folder and never where the folder is, so the same tree at two paths has one root. That
/// is what lets a lock recorded against a vendored dependency survive it being moved, and
/// what makes two peers comparing subtrees comparable at all. It is also why the root is
/// its own value and not a field of the manifest, which does carry `baseFolderPath`.
public enum FolderContentRoot {

    /// The first line of every document. Versioned because a recorded root outlives the
    /// release that wrote it: a change to the fold changes the tag, so a mismatch reads as
    /// "a different format" rather than as "a different tree".
    ///
    /// 3: a symbolic link inside its folder is a `link` line holding its target, where the
    /// fold read the bytes of what it named under its name (B-77).
    ///
    /// 4: a file's line carries its mode beside its hash, `hash <h> mode 755`, so a file
    /// made executable moves the root (B-132).
    public static let formatTag = "semel-folder-content-root 4"

    public static func document(of children: [(name: String, kind: FolderChildKind,
                                               content: FolderChildContent)]) -> String {
        let ordered = children.sorted { left, right in
            if left.name.utf8.lexicographicallyPrecedes(right.name.utf8) {
                return true
            }
            if right.name.utf8.lexicographicallyPrecedes(left.name.utf8) {
                return false
            }
            return left.kind.sortRank < right.kind.sortRank
        }

        var text = "\(formatTag)\n"
        for child in ordered {
            text += "\(child.kind.rawValue)\t\(child.content.token)\t\(child.name.utf8.count)\t\(child.name)\n"
        }
        return text
    }
}

// MARK: - The same fold over a folder on disk

extension FolderContentRoot {

    /// The root the engine will publish for `folder` once it has been pushed, computed from
    /// the disk: what `semel-swift prepare` records in a dependency's lock (B-06), so that
    /// a build compares the tree it was given with the tree that was vendored.
    ///
    /// Folded by `document(of:)` and hashed by `Sha256`, as the engine folds and interns,
    /// so the two cannot differ in the format. They could still differ in *what* is folded,
    /// so this walks what a push pushes and nothing else: the listing is
    /// `ExternalFileSystemLister`'s, the one `push` matches with, which leaves out every
    /// name starting with a dot — a checkout's `.github`, `.swiftpm`, `.gitignore` — folds a
    /// link that stays inside its folder as the link it is, without reading what it names,
    /// and follows any other link unless it points at a folder above it. And a subfolder
    /// holding no file at any depth is left out, because a push creates a folder only on
    /// the way to a file it pushes or when it is a link, so the engine never has a node for
    /// it.
    ///
    /// What a push does that this cannot see: a file removed from disk since an earlier push
    /// is still in the graph, because a push only adds. The engine's root then differs from
    /// this one, which is right — the build is reading a tree the lock does not describe.
    ///
    /// The walk is `FolderOnDisk`'s, the one `push` compares with (B-132), so the lock and
    /// the push cannot come to disagree about what a folder on disk folds to.
    public static func root(ofFolderAt folder: URL) throws -> DataObjectHash {
        let onDisk = FolderOnDisk.read(folderAt: folder.path)
        if let unreadable = onDisk.firstUnreadable {
            throw unreadable
        }
        return onDisk.contentRoot ?? emptyFolderRoot
    }

    /// The root of a folder holding nothing: what the engine publishes for a folder it has
    /// just made, and for a folder link whose referent holds nothing a push would push.
    public static var emptyFolderRoot: DataObjectHash {
        Sha256.hash(Data(document(of: []).utf8))
    }
}

/// Why a folder on disk could not be folded.
public enum FolderContentRootError: Error, CustomStringConvertible {
    case unreadable(path: String, reason: String)

    public var description: String {
        switch self {
        case .unreadable(let path, let reason):
            return "cannot read \(path) to fold its folder's content root: \(reason)"
        }
    }
}
