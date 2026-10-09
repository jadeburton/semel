// Checkpoints.swift
// SemelCore
//
// `checkpoint`, `checkpoints` and `restore` (B-146). A checkpoint is the input root's
// content root under a name: one hash, and every object below it is already in the store,
// so recording one copies nothing and restoring one reads the store and writes nodes.

import Foundation
import SemelDatabaseModels
import SemelNodeKit

/// A checkpoint is a value, not a time: it names the tree `input:` held, and two
/// checkpoints of one tree are one root whatever happened between them. Nothing here is
/// ordered by when it was taken; `checkpoints` lists them by name.
///
/// The root is the *whole* one (`Folder.contentRootOutputPort`), dot-names included,
/// because a restore has to bring back exactly what was held, not what a push of the disk
/// would send. Kept in the graph's database rather than as files in the tree: a checkpoint
/// is a fact about this engine's `input:`, and a tree checked out somewhere else has its
/// own.
public enum Checkpoints {

    /// The name `checkpoint` takes when it is given none.
    public static let defaultName = "latest"

    static let keyPrefix = "checkpoint/"

    /// Records the input root's content root under `name`, replacing what the name held,
    /// and returns it. The marks a push left are folded first, so the root is the one the
    /// tree has now rather than the one the last pass saw.
    @discardableResult
    public static func record(named name: String) throws -> DataObjectHash {
        try validate(name)
        try Folder.flushDirtyManifests()
        let root = try currentInputRoot()
        try DatabaseLayer.shared.metadata.upsert(key: keyPrefix + name, value: root)
        return root
    }

    /// Every checkpoint, by name.
    public static func all() throws -> [(name: String, contentRoot: DataObjectHash)] {
        try DatabaseLayer.shared.metadata.selectEntries(withExactPrefix: keyPrefix).map {
            (name: String($0.key.dropFirst(keyPrefix.count)), contentRoot: $0.value)
        }
    }

    /// Every recorded root, for the collector: what a checkpoint names is kept, and every
    /// object below it through the documents the collector reads through.
    static func recordedRoots(database: DatabaseLayer) throws -> [DataObjectHash] {
        try database.metadata.selectEntries(withExactPrefix: keyPrefix).map(\.value)
    }

    public static func root(named name: String) throws -> DataObjectHash {
        guard let root = try DatabaseLayer.shared.metadata.select(key: keyPrefix + name) else {
            throw CheckpointError.notFound(name: name, known: try all().map(\.name))
        }
        return root
    }

    /// A name is one segment a person can type and a key can hold: letters, digits, `.`,
    /// `_` and `-`.
    static func validate(_ name: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty, name.allSatisfy(allowed.contains), name != ".", name != ".." else {
            throw CheckpointError.invalidName(name)
        }
    }

    /// The input root's whole content root, read after a flush.
    static func currentInputRoot() throws -> DataObjectHash {
        guard case .value(let root) = try Folder.inputFileSystem.readFromOutputPort(Folder.contentRootOutputPort) else {
            throw CheckpointError.inputRootNotFolded
        }
        return root
    }

    // MARK: - Restoring

    /// What a restore did.
    public struct Restoration: Equatable {
        public let contentRoot: DataObjectHash
        /// How many paths it pushed, linked, made or removed.
        public let changedPaths: Int
    }

    /// Makes `input:` hold the tree checkpoint `name` names, recording every path it
    /// changes in `journal` first, as a push records. Files, links and modes are pushed
    /// where they differ, folders the checkpoint lacks are removed, and a subtree whose
    /// root already matches is not walked: the walk follows the two trees' documents down
    /// to where they differ, so restoring a tree one file away from the checkpoint reads a
    /// document per folder on the way to that file.
    ///
    /// One transaction: a restore that cannot finish — an object the store no longer
    /// holds, a link whose target the checkpoint does not have — changes nothing.
    public static func restore(named name: String, recordingInto journal: BatchJournal) throws -> Restoration {
        let target = try root(named: name)
        do {
            return try DatabaseLayer.shared.withTransaction {
                try Folder.flushDirtyManifests()
                var walk = RestoreWalk(checkpointRoot: target, journal: journal)
                try walk.restore(folder: .empty, to: target, from: try currentInputRoot())
                return Restoration(contentRoot: target, changedPaths: walk.changedPaths)
            }
        } catch {
            try journal.reloadRecordedPaths()
            throw error
        }
    }
}

public enum CheckpointError: Error, Equatable, CustomStringConvertible {
    case invalidName(String)
    case notFound(name: String, known: [String])
    /// The input root has no content root to record: it has not been folded.
    case inputRootNotFolded
    /// A document the checkpoint names is not in the store, or is not a content root.
    case unreadableDocument(path: String, hash: DataObjectHash)
    /// A file the checkpoint names whose bytes the store no longer holds.
    case missingObject(path: String, hash: DataObjectHash)
    /// A link whose target the checkpoint's tree does not hold.
    case unresolvableLink(path: String, target: String)

    public var description: String {
        switch self {
        case .invalidName(let name):
            return "'\(name)' is not a checkpoint name: one word of letters, digits, '.', '_' and '-'"
        case .notFound(let name, let known):
            let listing = known.isEmpty ? "there are none" : "there are \(known.joined(separator: ", "))"
            return "there is no checkpoint named '\(name)'; \(listing)"
        case .inputRootNotFolded:
            return "input: has no content root to record"
        case .unreadableDocument(let path, let hash):
            return "the checkpoint's folder input:/\(path) is not readable as a content root (\(hash))"
        case .missingObject(let path, let hash):
            return "the bytes of input:/\(path) (\(hash)) are no longer in the object store"
        case .unresolvableLink(let path, let target):
            return "the link input:/\(path) -> \(target) names nothing in the checkpoint"
        }
    }
}

// MARK: - The walk

/// What one name holds, in either tree, as far as a restore cares: a file, a link, a
/// folder, or nothing — a name nobody pushed and a removed source are nothing, as a tree a
/// push sends has no line for either.
private enum HeldEntry: Equatable {
    case file(hash: DataObjectHash, mode: UInt16)
    case link(target: String)
    case folder(root: DataObjectHash)

    init?(_ line: FolderContentRoot.Line) {
        switch (line.kind, line.content) {
        case (.file, .file(let hash, let mode)):
            self = .file(hash: hash, mode: mode)
        case (.link, .symbolicLinkTarget(let target)):
            self = .link(target: target)
        case (.folder, .hash(let root)):
            self = .folder(root: root)
        default:
            return nil
        }
    }

    var isPlainFolder: Bool {
        guard case .folder = self else {
            return false
        }
        return true
    }
}

/// What a link resolves to in the checkpoint's tree.
private enum Referent {
    case file(hash: DataObjectHash, mode: UInt16)
    case folder(root: DataObjectHash)
}

private struct RestoreWalk {
    let checkpointRoot: DataObjectHash
    let journal: BatchJournal
    private(set) var changedPaths = 0
    private var documents: [DataObjectHash: [String: FolderContentRoot.Line]] = [:]

    init(checkpointRoot: DataObjectHash, journal: BatchJournal) {
        self.checkpointRoot = checkpointRoot
        self.journal        = journal
    }

    /// Makes the folder at `folder` hold what `target` names, given that it holds what
    /// `current` names now.
    mutating func restore(folder: Path, to target: DataObjectHash, from current: DataObjectHash?) throws {
        guard target != current else {
            return
        }
        let wanted = try lines(of: target, at: folder)
        let held   = try current.map { try lines(of: $0, at: folder) } ?? [:]
        for name in Set(wanted.keys).union(held.keys).sorted() {
            let path      = folder / name
            let wantedEntry = wanted[name].flatMap(HeldEntry.init)
            let heldEntry   = held[name].flatMap(HeldEntry.init)
            guard let wantedEntry else {
                if heldEntry != nil {
                    try removeHeld(at: path)
                }
                continue
            }
            switch wantedEntry {
            case .file(let hash, let mode):
                guard heldEntry != wantedEntry else {
                    continue
                }
                try clearIfFolder(path, held: heldEntry)
                try pushFile(at: path, hash: hash, mode: mode, symbolicLinkTarget: nil)

            case .link(let linkTarget):
                switch try resolve(linkTarget, from: folder, linkPath: path) {
                case .file(let hash, let mode):
                    try clearIfFolder(path, held: heldEntry)
                    try pushFile(at: path, hash: hash, mode: mode, symbolicLinkTarget: linkTarget)
                case .folder(let root):
                    // A link to a folder is a folder node holding the target: anything else
                    // under the name — a file, a file link, a folder that is no link — goes.
                    let heldNode    = try Folder.inputFileSystem.childNode(path: path)
                    let isNotFolder = heldNode.map { $0.kind != Folder.kind } ?? false
                    if heldEntry?.isPlainFolder == true || isNotFolder {
                        try removeHeld(at: path)
                    }
                    try journal.recordPathAndFoldersAbove(path)
                    if try Folder.pushSymbolicLink(target: linkTarget, at: path) {
                        changedPaths += 1
                    }
                    try restore(folder: path, to: root, from: try ownRoot(at: path))
                }

            case .folder(let root):
                switch heldEntry {
                case .file?, .link?:
                    try removeHeld(at: path)
                case .folder?, nil:
                    break
                }
                try journal.recordPathAndFoldersAbove(path)
                try ensurePinnedFolder(at: path)
                if case .folder(let heldRoot)? = heldEntry {
                    try restore(folder: path, to: root, from: heldRoot)
                } else {
                    try restore(folder: path, to: root, from: try ownRoot(at: path))
                }
            }
        }
    }

    // MARK: Writing

    private mutating func pushFile(at path: Path, hash: DataObjectHash, mode: UInt16, symbolicLinkTarget: String?) throws {
        guard hash.isEmpty || DataObjectStore.shared.exists(hash: hash) else {
            throw CheckpointError.missingObject(path: path.string, hash: hash)
        }
        try journal.recordPathAndFoldersAbove(path)
        if try StaticFile.push(interned: hash, mode: mode, symbolicLinkTarget: symbolicLinkTarget, at: path) {
            changedPaths += 1
        }
    }

    private mutating func ensurePinnedFolder(at path: Path) throws {
        let before = try Folder.inputFileSystem.childNode(path: path)
        let wasPinned = try before.flatMap { try $0.nodeAsAny() as? Folder }.map { try $0.isPinned } ?? false
        _ = try Folder.inputFileSystem.ensureEntirePathExistsAsFolders(path, pinned: true)
        if !wasPinned {
            changedPaths += 1
        }
    }

    /// A folder, or a folder link, where the checkpoint has a file or a file link: it goes
    /// before the file is pushed under its name.
    private mutating func clearIfFolder(_ path: Path, held: HeldEntry?) throws {
        if case .folder? = held {
            try removeHeld(at: path)
            return
        }
        if case .link? = held, let node = try Folder.inputFileSystem.childNode(path: path), node.kind == Folder.kind {
            try removeHeld(at: path)
        }
    }

    /// Takes away what a path holds that a push leaves: a file with its bytes, a pinned
    /// folder and everything below it. A folder nobody pinned — one a formula only asks
    /// for — is not the person's to remove, so only what was pushed below it goes.
    private mutating func removeHeld(at path: Path) throws {
        guard let nodeRecord = try Folder.inputFileSystem.childNode(path: path) else {
            return
        }
        switch try nodeRecord.nodeAsAny() {
        case let file as StaticFile:
            guard try file.isPinned else {
                return
            }
            try journal.recordSubtree(at: path)
            try file.deleteInInputFileSystem()
            changedPaths += 1
        case let folder as Folder:
            guard try folder.isPinned else {
                for child in try nodeRecord.allChildren {
                    try removeHeld(at: path / (try child.requireName()))
                }
                return
            }
            try journal.recordSubtree(at: path)
            try folder.deleteInInputFileSystem()
            changedPaths += 1
        default:
            return
        }
    }

    // MARK: Reading

    /// The current root of the folder at `path` itself: what a folder link holds below it,
    /// which its parent's line, saying only that it is a link, does not.
    private func ownRoot(at path: Path) throws -> DataObjectHash? {
        guard let nodeRecord = try Folder.inputFileSystem.childNode(path: path), nodeRecord.kind == Folder.kind,
              case .value(let root) = try nodeRecord.readFromOutputPort(Folder.contentRootOutputPort) else {
            return nil
        }
        return root
    }

    private mutating func lines(of document: DataObjectHash, at path: Path) throws -> [String: FolderContentRoot.Line] {
        if let known = documents[document] {
            return known
        }
        guard let text = try? document.resolveAsString(), let lines = FolderContentRoot.lines(ofDocument: text) else {
            throw CheckpointError.unreadableDocument(path: path.string, hash: document)
        }
        var byName: [String: FolderContentRoot.Line] = [:]
        for line in lines {
            byName[line.name] = line
        }
        documents[document] = byName
        return byName
    }

    /// What a link at `linkPath`, in `folder`, names in the checkpoint's tree: its target
    /// read relative to its folder, every link on the way followed — a framework's
    /// `Versions/Current/Tiny` goes through `Current` — up to a bound that stops a cycle.
    private mutating func resolve(_ target: String, from folder: Path, linkPath: Path,
                                  hops: Int = 0) throws -> Referent {
        let unresolvable = CheckpointError.unresolvableLink(path: linkPath.string, target: target)
        guard hops < 32 else {
            throw unresolvable
        }
        var segments = folder.segments
        for segment in target.split(separator: "/").map(String.init) {
            switch segment {
            case ".", "":
                continue
            case "..":
                guard !segments.isEmpty else {
                    throw unresolvable
                }
                segments.removeLast()
            default:
                segments.append(segment)
            }
        }

        var root = checkpointRoot
        var walked = Path.empty
        for (index, name) in segments.enumerated() {
            guard let line = try lines(of: root, at: walked)[name], let entry = HeldEntry(line) else {
                throw unresolvable
            }
            let isLast = index == segments.count - 1
            switch entry {
            case .file(let hash, let mode):
                guard isLast else {
                    throw unresolvable
                }
                return .file(hash: hash, mode: mode)
            case .folder(let folderRoot):
                root   = folderRoot
                walked = walked / name
            case .link(let innerTarget):
                let referent = try resolve(innerTarget, from: walked, linkPath: linkPath, hops: hops + 1)
                guard !isLast else {
                    return referent
                }
                guard case .folder(let folderRoot) = referent else {
                    throw unresolvable
                }
                root   = folderRoot
                walked = walked / name
            }
        }
        return .folder(root: root)
    }
}
