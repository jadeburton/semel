// LockBarrier.swift
// SemelCore
//
// A lock is a write barrier, enforced at `commit` (B-146). A folder `F` is locked when
// `F.semel-lock` is in `input:` beside it, the rule the converter already finds a lock by.
// A batch that changes anything below a locked folder must also bring the lock that folder
// now matches, or take the lock away; otherwise the batch is taken back whole.

import Foundation
import SemelDatabaseModels
import SemelNodeKit

/// Why the outermost `commit` refused a batch: the folder, its lock, what the lock says the
/// folder holds, what the batch would have left there, and the batch's paths that moved it.
/// By the time this is thrown the batch has been replayed: `input:` is as it was before the
/// batch began, and the batch is closed.
public struct BatchRejection: Error, Equatable {

    /// What the lock in `input:` says, as far as it can be read.
    public enum Expectation: Equatable {
        /// The lock records this root under this Semel's fold.
        case contentRoot(DataObjectHash)
        /// The lock was folded under another format, so its root cannot be compared: the
        /// folder may hold exactly what was vendored. Shut rather than open, as an
        /// unreadable lock is.
        case otherFold(fold: String, contentRoot: DataObjectHash)
        /// The lock's text is not a lock; the error names the line.
        case unreadable(DependencyLockError)
    }

    /// Relative to `input:`.
    public let folder: Path
    public let lock: Path
    public let expected: Expectation
    /// The folder's pushed content root after the batch; nil when the batch left no folder
    /// there.
    public let found: DataObjectHash?
    /// The batch's paths at or below the folder, and the lock's own when the batch changed
    /// it, whose content the batch changed — in path order.
    public let paths: [Path]
}

public enum LockBarrier {

    /// Checks the journal's batch against the locks in `input:` and closes it: the batch
    /// stands and nil is returned, or it is replayed and the rejection returned.
    ///
    /// A batch touching no locked folder reads one lock path per folder it touched and
    /// folds nothing. One that does flushes the marks its writes left — the fold the next
    /// pass would have made, made now, so the roots compared are the batch's — and reads
    /// each locked folder's pushed root (`Folder.pushedContentRootOutputPort`, the fold the
    /// lock records, B-143). The flush is inside a savepoint that a rejection rolls back,
    /// so a rejected batch's folds are never published; the replay then marks the folders
    /// again and a second flush folds them back to what they held, which writes no port
    /// that moved and so schedules nothing.
    public static func commit(_ journal: BatchJournal) throws -> BatchRejection? {
        let foldersToCheck = try lockedFolders(touchedBy: journal.paths)
        guard !foldersToCheck.isEmpty else {
            try journal.close()
            return nil
        }

        var rejection: BatchRejection?
        do {
            try DatabaseLayer.shared.withSavepoint {
                try Folder.flushDirtyManifests()
                for (folder, lockHash) in foldersToCheck {
                    if let refused = try check(folder: folder, lockHash: lockHash, journal: journal) {
                        rejection = refused
                        throw RollingBack()
                    }
                }
            }
        } catch is RollingBack {
            // The savepoint is undone; `rejection` says why.
        }

        guard let rejection else {
            try journal.close()
            return nil
        }
        try journal.replay()
        try Folder.flushDirtyManifests()
        return rejection
    }

    /// Thrown out of the savepoint to roll back the folds a rejected batch made.
    private struct RollingBack: Error {}

    // MARK: - Which folders are locked

    /// The locked folders the paths fall under, each with the hash of its lock, in path
    /// order: for each path, the first folder from the path itself upwards whose lock
    /// holds a value in `input:` — the lock as the batch left it, so a batch that brought a
    /// lock is checked against it and one that took the lock away is free. A path that is
    /// itself a lock names its folder too: a lock edited alone must still match.
    static func lockedFolders(touchedBy paths: [Path]) throws -> [(folder: Path, lock: DataObjectHash)] {
        var lockByFolder: [Path: DataObjectHash?] = [:]
        func lockHash(of folder: Path) throws -> DataObjectHash? {
            if let known = lockByFolder[folder] {
                return known
            }
            let hash = try heldValue(at: lockPath(of: folder))
            lockByFolder[folder] = hash
            return hash
        }

        var locked: [Path: DataObjectHash] = [:]
        for path in paths {
            if let name = path.lastComponent, let folder = folder(lockedBy: name, at: path),
               let hash = try lockHash(of: folder) {
                locked[folder] = hash
            }
            var candidate: Path? = path
            while let folder = candidate, !folder.isEmpty {
                if let hash = try lockHash(of: folder) {
                    locked[folder] = hash
                    break
                }
                candidate = folder.deletingLastComponent
            }
        }
        return locked.sorted { $0.key.string.utf8.lexicographicallyPrecedes($1.key.string.utf8) }
            .map { (folder: $0.key, lock: $0.value) }
    }

    /// `Dependencies/GRDB.swift.semel-lock` locks `Dependencies/GRDB.swift`.
    static func lockPath(of folder: Path) -> Path {
        Path(DependencyLock.lockPath(forDependencyAt: folder.string))
    }

    /// The folder a lock at `path` would lock, when its name is a lock's.
    private static func folder(lockedBy name: String, at path: Path) -> Path? {
        let suffix = ".\(DependencyLock.fileExtension)"
        guard name.hasSuffix(suffix), name.count > suffix.count else {
            return nil
        }
        let folderName = String(name.dropLast(suffix.count))
        return (path.deletingLastComponent ?? .empty) / folderName
    }

    /// The hash a file in `input:` holds, nil when there is no file there or it holds no
    /// value: a lock nobody pushed, or one taken back out, locks nothing.
    private static func heldValue(at path: Path) throws -> DataObjectHash? {
        guard let nodeRecord = try Folder.inputFileSystem.childNode(path: path),
              let file = try nodeRecord.nodeAsAny() as? StaticFile,
              case .value(let hash)? = try file.read() else {
            return nil
        }
        return hash
    }

    // MARK: - One folder

    /// The rejection for one locked folder, or nil when its lock matches what the batch
    /// left in it.
    private static func check(folder: Path, lockHash: DataObjectHash, journal: BatchJournal) throws -> BatchRejection? {
        let lock = lockPath(of: folder)
        let found = try pushedContentRoot(of: folder)
        let expected: BatchRejection.Expectation
        do {
            let parsed = try DependencyLock.parse(try lockHash.resolveAsString())
            guard parsed.fold == FolderContentRoot.formatTag else {
                return try rejection(folder: folder, lock: lock,
                                     expected: .otherFold(fold: parsed.fold, contentRoot: parsed.contentRoot),
                                     found: found, journal: journal)
            }
            guard parsed.contentRoot != found else {
                return nil
            }
            expected = .contentRoot(parsed.contentRoot)
        } catch let error as DependencyLockError {
            expected = .unreadable(error)
        }
        return try rejection(folder: folder, lock: lock, expected: expected, found: found, journal: journal)
    }

    private static func rejection(folder: Path, lock: Path, expected: BatchRejection.Expectation,
                                  found: DataObjectHash?, journal: BatchJournal) throws -> BatchRejection {
        BatchRejection(folder: folder, lock: lock, expected: expected, found: found,
                       paths: try changedPaths(below: folder, lock: lock, journal: journal))
    }

    /// The folder's pushed root as the flush just folded it; nil when no folder is there.
    private static func pushedContentRoot(of folder: Path) throws -> DataObjectHash? {
        guard let nodeRecord = try Folder.inputFileSystem.childNode(path: folder), nodeRecord.kind == Folder.kind,
              case .value(let hash) = try nodeRecord.readFromOutputPort(Folder.pushedContentRootOutputPort) else {
            return nil
        }
        return hash
    }

    /// The journal's paths at or below `folder`, and the lock's, whose content the batch
    /// changed: a file or link whose rows differ from the record, and a folder pushed or
    /// taken away. A folder made on the way to a file is the file's doing, and a path
    /// pushed again unchanged moved nothing.
    private static func changedPaths(below folder: Path, lock: Path, journal: BatchJournal) throws -> [Path] {
        let records = try journal.records()
        var changed: [Path] = []
        for path in journal.paths where path.hasPrefix(folder) || path == lock {
            guard let before = records[path] else {
                continue
            }
            let after = try BatchJournal.currentRecord(at: path)
            guard before != after else {
                continue
            }
            switch (before, after) {
            case (.file, _), (_, .file):
                changed.append(path)
            default:
                if before.holdsContent != after.holdsContent {
                    changed.append(path)
                }
            }
        }
        return changed
    }
}
