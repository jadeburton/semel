// RequestHandler+Files.swift
// SemelServer
//
// The file verbs: what push, ls, rm and cp do to the graph. Paths arrive absolute within
// the named file system and already resolved by the client, so `..` never reaches here.

import Foundation
import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol

extension RequestHandler {

    // MARK: - list

    func list(fileSystem: FileSystemKind, pattern: String) throws -> DaemonResponse {
        let root    = try rootFolder(fileSystem)
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: root))
        let matches = try matcher.findAllMatching(pathOrWildcard: Path(pattern))

        return .list(entries: try matches.map { try listEntry(for: $0, in: root) })
    }

    /// The word for one state, by case. The states are not interchangeable — one settles by
    /// itself, one is a failure to act on, one is neither — so each keeps its own word all
    /// the way to the client.
    ///
    /// Which of them a name can show depends on which file system it is in. A source under
    /// `input:` has no inputs and is never scheduled, so it is there, `deleted` once the
    /// user removes it, or waiting for a push that may never come. An artifact under
    /// `output:` is pinned by its *input* port and shows what the node that builds it says:
    /// the built value, `pending` mid-build, `failed` from anything that stopped it — a
    /// removed source included — or nothing produced when a source the formula names was
    /// never pushed. `deleted` belongs to `input:`, where the user's own hand put it.
    private func status(for state: FileWildcardEntryState) -> EntryStatus {
        switch state {
        case .present:     return .none
        case .pending:     return .pending
        case .notProduced: return .notProduced
        case .deleted:     return .deleted
        case .failed:      return .failed
        }
    }

    /// What `ls` shows for one match. A file's size and mode come from its value; a file
    /// with no value keeps the default mode and says which state it is in, which is the
    /// more useful word than the one for a name nothing reads.
    private func listEntry(for match: FileWildcardEntry, in root: NodeRecord) throws -> ListEntry {
        var status = match.state.map(status(for:)) ?? .none
        if status == .none, match.isUnreferenced {
            status = .unreferenced
        }

        guard case .file = match.kind else {
            return ListEntry(path: match.path.string, kind: .folder, size: nil, mode: nil, status: status)
        }

        var size: Int?
        var mode: UInt16?

        if let fileNode = try root.childNode(path: match.path),
           let file     = try fileNode.nodeAsAny() as? FileType,
           let value    = try file.read() {

            switch value {

            case .value(let hash):
                size = hash.size()
                if let provider = file as? FileMetadataProvider,
                   let metadata = try? provider.readFileMetadata() {
                    mode = metadata.mode ?? FileMetadata.defaultMode
                } else {
                    mode = FileMetadata.defaultMode
                }

            case .noValue:
                // Why it has no value is the match's state: the lister read it from this
                // same port, so there is one answer and the word is already chosen.
                mode = FileMetadata.defaultMode
            }
        }

        return ListEntry(path: match.path.string, kind: .file, size: size, mode: mode, status: status)
    }

    // MARK: - push

    /// Records each file, its bytes already interned, at its path in the input file system
    /// with its mode beside it, creating the folders on the way: one `pushFile` after
    /// another, in order, in one turn of the queue and one transaction. A file the graph
    /// refuses is answered as its own `pushFile` would have been, and the rest are recorded
    /// all the same (B-130); a failure of the machine is the whole request's, as it stops
    /// the server.
    ///
    /// One transaction, because a file's push is otherwise several — a commit for each
    /// folder made, for the file's node, for each port written — and a read transaction
    /// for each read between them: a cold push of a tree spent a fifth of its time opening
    /// and committing them. `withTransactionPerStep` keeps each of those transactions'
    /// boundaries inside the one, so a refused file leaves behind what it left before.
    func pushFiles(_ files: [InternedFile]) throws -> [PushedFileOutcome] {
        try database.withTransactionPerStep {
            try files.map { file in
                do {
                    return .stored(didChange: try StaticFile.push(interned: file.contentHash, mode: file.mode,
                                                                  at: Path(file.path)))
                } catch let error as any UnrecoverableError {
                    throw error
                } catch {
                    return .failed(error: Self.errorResponse(for: error))
                }
            }
        }
    }

    /// A symbolic link (B-77). To a file: a file whose metadata names the target and whose
    /// bytes are what it names. To a folder: the folder, pinned as a pushed folder is, with
    /// the target on its `symbolicLink` port; its files arrive as pushes of their own.
    /// Returns whether anything changed.
    func pushSymbolicLink(path: String, target: String, referent: SymbolicLinkReferent, body: Data) throws -> DaemonResponse {
        switch referent {
        case .file(let mode):
            return .pushFile(didChange: try StaticFile.push([UInt8](body), mode: mode, symbolicLinkTarget: target, at: Path(path)))
        case .folder:
            return .pushFile(didChange: try Folder.pushSymbolicLink(target: target, at: Path(path)))
        }
    }

    func pushFolder(path: String) throws -> DaemonResponse {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path(path), pinned: true)
        return .ok
    }

    // MARK: - What a push compares (B-132)

    /// The roots of the folder at `path` and every folder below it, as a JSON array of
    /// `HeldFolderRoot` for the reply's body.
    func contentRoots(path: String) throws -> Data {
        let roots = try HeldTree.folderRoots(below: Path(path)).map {
            HeldFolderRoot(path: $0.path.string, contentRoot: $0.contentRoot, isPinned: $0.isPinned, hiddenFiles: $0.hiddenFiles)
        }
        return try MessageCoder.encode(roots)
    }

    /// The children of each folder at `paths`, as a JSON array of `HeldFolder` for the
    /// reply's body; a path with no folder is left out.
    func folderChildren(paths: [String]) throws -> Data {
        var folders: [HeldFolder] = []
        for path in paths {
            guard let children = try HeldTree.children(ofFolderAt: Path(path)) else {
                continue
            }
            folders.append(HeldFolder(path: path, children: children.map { child in
                HeldChild(name:               child.name,
                          kind:               child.kind == .folder ? .folder : .file,
                          contentHash:        child.contentHash,
                          mode:               child.mode,
                          symbolicLinkTarget: child.symbolicLinkTarget,
                          isPinned:           child.isPinned)
            }))
        }
        return try MessageCoder.encode(folders)
    }

    // MARK: - remove

    /// Deletes every match in the input file system. Deletions that succeed stand even if a
    /// later one fails; the failures are reported together, and the paths that were removed
    /// are not repeated back in that case.
    ///
    /// Files and folders come back apart because the client says each differently: a
    /// wildcard can match every file of a folder without matching the folder.
    func remove(pattern: String) throws -> DaemonResponse {
        let root    = try engine.inputFileSystem
        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: root))
        let matches = try matcher.findAllMatching(pathOrWildcard: Path(pattern))

        var removedFiles:   [String] = []
        var removedFolders: [String] = []
        var failures:       [String] = []

        for match in matches {
            guard let child = try root.childNode(path: match.path) else {
                failures.append("Child not found: \(match.path)")
                continue
            }
            guard let deletable = try child.nodeAsAny() as? UserDeletable else {
                failures.append("Child not deletable: \(match.path)")
                continue
            }
            try deletable.deleteInInputFileSystem()
            if case .folder = match.kind {
                removedFolders.append(match.path.string)
            } else {
                removedFiles.append(match.path.string)
            }
        }

        guard failures.isEmpty else {
            throw HandlerFailure.node(description: failures.joined(separator: "\n"))
        }
        return .remove(removedFiles: removedFiles, removedFolders: removedFolders)
    }

    // MARK: - fetch

    /// A file's bytes and mode, the bytes in the frame body; or a symbolic link's target,
    /// with no body, since what a client writes for one is the link.
    func fetch(fileSystem: FileSystemKind, path: String) throws -> (DaemonResponse, Data?) {
        let root = try rootFolder(fileSystem)

        guard let fileNode = try root.childNode(path: Path(path)) else {
            throw HandlerFailure.pathNotFound(path: path)
        }
        guard let file = try fileNode.nodeAsAny() as? FileType else {
            throw HandlerFailure.node(description: "Object \(path) is not a file")
        }

        switch try file.read() {

        case .value(let hash):
            var mode = FileMetadata.defaultMode
            if let provider = try fileNode.nodeAsAny() as? FileMetadataProvider,
               let metadata = try provider.readFileMetadata() {
                if let target = metadata.symbolicLinkTarget {
                    return (.symbolicLink(target: target), nil)
                }
                mode = metadata.mode ?? FileMetadata.defaultMode
            }
            return (.fetch(mode: mode), Data(try hash.resolve()))

        case .noValue(let reason):
            throw HandlerFailure.node(description: "File \(path) has no content: \(reason)")

        case nil:
            throw HandlerFailure.node(description: "File \(path) has a nil value")
        }
    }
}
