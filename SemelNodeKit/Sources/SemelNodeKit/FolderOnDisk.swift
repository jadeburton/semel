// FolderOnDisk.swift
// SemelNodeKit
//
// A folder on disk as a push sees it: what it would send, in the order it would send it,
// with the content root the engine will publish for each folder once it has (B-132). The
// client compares these roots with the ones the server holds and sends only where they
// differ; `prepare` records the top one in a dependency's lock (B-06). One walk for both,
// so that a push and a lock cannot come to disagree about what a folder folds to.

import Foundation
import SemelDatabaseModels

/// A folder below the tree a push reads, walked as `ExternalFileSystemLister` lists it.
///
/// What is here is what a push sends and nothing else: every name starting with a dot is
/// left out but a file the server already holds under it (`hiddenFiles`) or one the lock
/// beside a locked folder names below it (`DependencyLock.hiddenFiles`), a link inside its
/// own folder is the link it is, any other link is followed unless it points at a folder
/// above it, and a subfolder holding nothing a push would push is left out — a push creates
/// a folder only on the way to a file, or when it is a link.
public struct FolderOnDisk {
    /// Where the folder is, relative to the directory the walk was rooted at: the path a
    /// push sends it under.
    public let path: Path
    /// The root the engine will publish for this folder once what is here has been pushed:
    /// `FolderContentRoot.document(of:)` over the lines below, hashed as the engine interns.
    /// Nil when a file below could not be read, so the root cannot be known; a client then
    /// compares what it can, file by file.
    public let contentRoot: DataObjectHash?
    /// For a folder that is a symbolic link inside its own folder, what the link holds. The
    /// folder above folds the link as that target; the root here is over what the link
    /// names, which a push stores below the link's path as it stores any folder's files.
    public let symbolicLinkTarget: String?
    /// What the folder holds, in the lister's order — by name — which is the order a push
    /// sends it in.
    public let children: [Child]

    public enum Child {
        case file(FileOnDisk)
        case folder(FolderOnDisk)
    }

    /// The first file below that could not be read, for a caller that has to refuse to
    /// fold what it cannot see (`FolderContentRoot.root(ofFolderAt:)`).
    public var firstUnreadable: FolderContentRootError? {
        for child in children {
            switch child {
            case .file(let file):
                if let unreadable = file.unreadable {
                    return unreadable
                }
            case .folder(let folder):
                if let unreadable = folder.firstUnreadable {
                    return unreadable
                }
            }
        }
        return nil
    }

    /// Every file and folder link at any depth below, in the order a push sends them —
    /// the order `<folder>/**/*` matches in: what is directly in a folder, by name, and then
    /// what is in each of its subfolders. What `push` sends for a folder the server does
    /// not hold.
    public var entriesToPush: [FileWildcardEntry] {
        var entries: [FileWildcardEntry] = []
        for child in children {
            switch child {
            case .file(let file):
                entries.append(file.entry)
            case .folder(let folder):
                if let linkEntry = folder.linkEntry {
                    entries.append(linkEntry)
                }
            }
        }
        for case .folder(let folder) in children {
            entries.append(contentsOf: folder.entriesToPush)
        }
        return entries
    }

    /// For a folder that is a link pushed as one, the entry a push sends for the link.
    public var linkEntry: FileWildcardEntry? {
        symbolicLinkTarget.map {
            FileWildcardEntry(path: path, kind: .folder, state: nil, isUnreferenced: false, symbolicLinkTarget: $0)
        }
    }

    /// How many files there are at any depth below, links to files included: what a push
    /// counts as files when it sends none of them.
    public var fileCount: Int {
        children.reduce(0) { total, child in
            switch child {
            case .file:               return total + 1
            case .folder(let folder): return total + folder.fileCount + (folder.symbolicLinkTarget == nil ? 0 : 1)
            }
        }
    }
}

/// A file below the tree a push reads.
public struct FileOnDisk {
    /// As the lister gave it, with its path relative to the walk's root: what `push` sends.
    public let entry: FileWildcardEntry
    public let absolutePath: String
    /// The hash of the bytes, by `Sha256`'s rule, as the engine names what it stores. Nil
    /// for a link, which the fold reads as its target and not its bytes, and for a file
    /// that could not be read.
    public let contentHash: DataObjectHash?
    /// The mode a push sends: the file's permission bits, links followed.
    public let mode: UInt16
    public let unreadable: FolderContentRootError?

    public var path: Path {
        entry.path
    }

    public var symbolicLinkTarget: String? {
        entry.symbolicLinkTarget
    }

    /// The bytes' hash for a link too, which a push sends as what it names: compared only
    /// where a folder's root has already said something below it differs.
    public func contentHashFollowingLinks() -> DataObjectHash? {
        if let contentHash {
            return contentHash
        }
        guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: absolutePath), options: .mappedIfSafe) else {
            return nil
        }
        return Sha256.hash(bytes)
    }
}

// MARK: - The walk

extension FolderOnDisk {

    /// The folder at `relativePath` below `baseDirectory`, leaving out every path
    /// `isExcluded` names — the export folder a build writes into the tree it pushes.
    /// `symbolicLinkTarget` is what the folder holds when it is itself a link pushed as one.
    ///
    /// `hiddenFiles` names, by the path of their folder relative to `baseDirectory`, the
    /// dot-named files the server holds there (B-77 item 5): each one still on disk is
    /// walked and folded as any file is, since the engine folds it into its folder's root.
    ///
    /// The walk adds the ones a lock names (B-143): a folder `F` beside `F.semel-lock`, at
    /// or above `relativePath` or anywhere below it, has each dot-named file its lock names
    /// walked as well. Those are the resources its manifest declares, which `prepare` folded
    /// into the lock's root; read here, a push of the folder sends them, so the engine's
    /// root and the lock's agree by construction. `prepare`'s own fold of a vendored folder
    /// is the folder alone, with no lock above it, and is told the same names.
    public static func read(_ relativePath: Path, under baseDirectory: String, symbolicLinkTarget: String? = nil,
                            hiddenFiles: [String: [String]] = [:],
                            excluding isExcluded: (Path) -> Bool = { _ in false }) -> FolderOnDisk {
        let lister = ExternalFileSystemLister(rootDirectoryPath: baseDirectory)
        let absolutePath = relativePath.isEmpty ? baseDirectory
                                                : (baseDirectory as NSString).appendingPathComponent(relativePath.string)
        var hiddenFiles = hiddenFiles
        var lockedFolder = Path.empty
        for segment in relativePath.segments {
            lockedFolder = lockedFolder / segment
            let lockPath = (baseDirectory as NSString).appendingPathComponent(DependencyLock.lockPath(forDependencyAt: lockedFolder.string))
            addHiddenFiles(ofLockAt: lockPath, lockedFolder: lockedFolder, to: &hiddenFiles)
        }

        // Listed first, read after, and read on every core: opening and hashing each file
        // is most of what a push of an unchanged tree costs the client, and the files are
        // independent of one another.
        var pending: [(entry: FileWildcardEntry, absolutePath: String)] = []
        let listed = list(absolutePath: absolutePath, relativePath: relativePath, symbolicLinkTarget: symbolicLinkTarget,
                          lister: lister, hiddenFiles: hiddenFiles, isExcluded: isExcluded, pending: &pending)
        var files = [FileOnDisk?](repeating: nil, count: pending.count)
        files.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: pending.count) { index in
                slots[index] = FileOnDisk(listedAs: pending[index].entry, at: pending[index].absolutePath)
            }
        }
        return fold(listed, files: files.compactMap { $0 })
    }

    /// The folder at `absolutePath`, as its own root: what `prepare` folds a vendored
    /// dependency from, with the dot-named files its lock names (`hiddenFiles`, relative to
    /// the folder) walked as a push of the folder walks them.
    public static func read(folderAt absolutePath: String, hiddenFiles: [String] = []) -> FolderOnDisk {
        let lock = DependencyLock(contentRoot: "", fold: "", hiddenFiles: hiddenFiles)
        return read(.empty, under: absolutePath, hiddenFiles: lock.hiddenFilesByFolder())
    }

    /// A folder as listed, before any file in it has been read: its files by their place
    /// in the walk's list of files to read.
    private struct ListedFolder {
        let path: Path
        let symbolicLinkTarget: String?
        var children: [ListedChild]
    }

    private enum ListedChild {
        case file(index: Int)
        case folder(ListedFolder)
    }

    /// Adds the dot-named files the lock at `lockPath` names below `lockedFolder`, when there
    /// is a lock there that reads; a lock that does not read names none, and the barrier
    /// refuses what it was to lock.
    private static func addHiddenFiles(ofLockAt lockPath: String, lockedFolder: Path, to hiddenFiles: inout [String: [String]]) {
        guard let data = FileManager.default.contents(atPath: lockPath),
              let lock = try? DependencyLock.parse(String(decoding: data, as: UTF8.self)) else {
            return
        }
        hiddenFiles.merge(lock.hiddenFilesByFolder(under: lockedFolder)) { held, named in held + named.filter { !held.contains($0) } }
    }

    private static func list(absolutePath: String, relativePath: Path, symbolicLinkTarget: String?,
                             lister: ExternalFileSystemLister, hiddenFiles: [String: [String]], isExcluded: (Path) -> Bool,
                             pending: inout [(entry: FileWildcardEntry, absolutePath: String)]) -> ListedFolder {
        var folder = ListedFolder(path: relativePath, symbolicLinkTarget: symbolicLinkTarget, children: [])
        var entries = lister.allFiles(inDirectoryPath: absolutePath)
        var hiddenFiles = hiddenFiles
        let names = Set(entries.map(\.path.string))
        for entry in entries where entry.kind == .folder
            && names.contains(DependencyLock.lockPath(forDependencyAt: entry.path.string)) {
            let lockPath = (absolutePath as NSString).appendingPathComponent(DependencyLock.lockPath(forDependencyAt: entry.path.string))
            addHiddenFiles(ofLockAt: lockPath, lockedFolder: relativePath / entry.path.string, to: &hiddenFiles)
        }
        let hidden = (hiddenFiles[relativePath.string] ?? []).compactMap {
            lister.hiddenFile(named: $0, inDirectoryPath: absolutePath)
        }
        if !hidden.isEmpty {
            entries = (entries + hidden).sorted { $0.path.string < $1.path.string }
        }
        for listed in entries {
            let name          = listed.path.string
            let childRelative = relativePath / name
            guard !isExcluded(childRelative) else {
                continue
            }
            let childAbsolute = (absolutePath as NSString).appendingPathComponent(name)
            switch listed.kind {
            case .file:
                let entry = FileWildcardEntry(path: childRelative, kind: .file, state: nil, isUnreferenced: false,
                                              symbolicLinkTarget: listed.symbolicLinkTarget)
                folder.children.append(.file(index: pending.count))
                pending.append((entry, childAbsolute))
            case .folder:
                let subfolder = list(absolutePath: childAbsolute, relativePath: childRelative,
                                     symbolicLinkTarget: listed.symbolicLinkTarget, lister: lister,
                                     hiddenFiles: hiddenFiles, isExcluded: isExcluded, pending: &pending)
                folder.children.append(.folder(subfolder))
            }
        }
        return folder
    }

    /// The fold over a listed folder, now that its files have been read.
    private static func fold(_ listed: ListedFolder, files: [FileOnDisk]) -> FolderOnDisk {
        var children: [Child] = []
        var lines: [(name: String, kind: FolderChildKind, content: FolderChildContent)] = []
        var foldable = true

        for child in listed.children {
            switch child {
            case .file(let index):
                let file = files[index]
                let name = file.path.lastComponent ?? ""
                children.append(.file(file))
                // A link, to a file or to a folder, is what it holds, and what it names is
                // folded where it is.
                if let target = file.symbolicLinkTarget {
                    lines.append((name, .link, .symbolicLinkTarget(target)))
                    continue
                }
                guard let hash = file.contentHash else {
                    foldable = false
                    continue
                }
                lines.append((name, .file, .file(hash: hash, mode: file.mode)))

            case .folder(let listedSubfolder):
                let subfolder = fold(listedSubfolder, files: files)
                let name = subfolder.path.lastComponent ?? ""
                if let target = subfolder.symbolicLinkTarget {
                    lines.append((name, .link, .symbolicLinkTarget(target)))
                }
                // A link stands whatever it names; any other folder is pushed only on the
                // way to something below it.
                guard subfolder.symbolicLinkTarget != nil || !subfolder.children.isEmpty else {
                    continue
                }
                children.append(.folder(subfolder))
                guard subfolder.symbolicLinkTarget == nil else {
                    continue
                }
                guard let subfolderRoot = subfolder.contentRoot else {
                    foldable = false
                    continue
                }
                lines.append((name, .folder, .hash(subfolderRoot)))
            }
        }

        let contentRoot = foldable ? Sha256.hash(Data(FolderContentRoot.document(of: lines).utf8)) : nil
        return FolderOnDisk(path: listed.path, contentRoot: contentRoot, symbolicLinkTarget: listed.symbolicLinkTarget,
                            children: children)
    }
}

extension FileOnDisk {

    /// Reads and hashes the file, unless it is a link, whose bytes the fold does not read.
    init(listedAs entry: FileWildcardEntry, at absolutePath: String) {
        self.entry        = entry
        self.absolutePath = absolutePath
        self.mode         = PushedContent.mode(ofFileAt: absolutePath)

        guard entry.symbolicLinkTarget == nil else {
            contentHash = nil
            unreadable  = nil
            return
        }
        do {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: absolutePath), options: .mappedIfSafe)
            contentHash = Sha256.hash(bytes)
            unreadable  = nil
        } catch {
            contentHash = nil
            unreadable  = .unreadable(path: absolutePath, reason: error.localizedDescription)
        }
    }
}
