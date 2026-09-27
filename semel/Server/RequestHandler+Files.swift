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

    /// Interns the bytes and stores them at `path` in the input file system, creating the
    /// folders on the way. Returns whether the content changed.
    ///
    /// TODO: `mode` is carried on the wire but not stored — `StaticFile` has no metadata
    /// port, and push has never preserved modes. Wire it through when it gains one.
    func pushFile(path: String, mode: UInt16, body: Data) throws -> DaemonResponse {
        let relativePath = Path(path)
        let root         = try engine.inputFileSystem

        _ = try root.ensureEntirePathExistsAsFolders(relativePath.deletingLastComponent ?? .empty, pinned: true)

        let fullPath      = Path(FileSystemName.input) / relativePath
        let graphSpecNode = GraphSpecNode(StaticFile.self, properties: [StaticFile.pathProperty: fullPath.string])
        let (fromNode, _) = try graphSpecNode.findOrCreateMatchingNode()

        guard let staticFile = try fromNode.nodeAsAny() as? StaticFile else {
            throw HandlerFailure.node(description: "push: \(path): the graph holds a non-file node at this path")
        }

        let didChange = try staticFile.replaceContent([UInt8](body).intern())
        return .pushFile(didChange: didChange)
    }

    func pushFolder(path: String) throws -> DaemonResponse {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path(path), pinned: true)
        return .ok
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

    /// A file's bytes and mode. The bytes travel in the frame body.
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
