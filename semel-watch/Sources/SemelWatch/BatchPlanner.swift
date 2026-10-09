// BatchPlanner.swift
// SemelWatch
//
// A batch of changed paths, read against the disk, becomes the commands a person would
// type for it (B-126).

import Foundation
import SemelNodeKit

/// One command a batch issues: a path to push, or a path to remove from `input:`. Typed,
/// so that nothing between the planner and the interpreter is text read back; it prints
/// as the command a person would type, which is what a test compares and a reader reads.
public enum WatchCommand: Equatable, CustomStringConvertible {
    case push(Path)
    case remove(Path)

    public var description: String {
        switch self {
        case .push(let path):   return "push \(path)"
        case .remove(let path): return "rm \(path)"
        }
    }
}

/// What the graph holds of the input file system, asked of a path the disk no longer has
/// — is there anything to remove? — and of a dot-named file, which is a source only when
/// it was pushed by its name; and, for a watched folder, everything held below it, which
/// is what a mirror compares with the disk. The interpreter in `semel-watch`; a set in a
/// test.
public protocol InputHoldings {
    func holds(_ path: Path) throws -> Bool
    /// Every file and folder held below `folder`, at any depth, dot-names among them; none
    /// when the graph does not hold the folder.
    func holdings(below folder: Path) throws -> [FileWildcardEntry]
    /// The folders at or below `folder` that are locked (B-146): each with a
    /// `<folder>.semel-lock` held beside it, which is the engine's own rule for a lock.
    func lockedFolders(below folder: Path) throws -> [Path]
}

extension InputHoldings {

    /// From everything held below the folder, and the folder's own lock: right for any
    /// holdings, and what one that can ask the graph a narrower question replaces.
    public func lockedFolders(below folder: Path) throws -> [Path] {
        var locked = try holdings(below: folder).compactMap { entry -> Path? in
            guard entry.kind == .file else {
                return nil
            }
            return LockedFolder.folder(lockedBy: entry.path)
        }
        if !folder.isEmpty, try holds(LockedFolder.lockPath(of: folder)) {
            locked.append(folder)
        }
        return locked.sorted(by: Path.precedes)
    }
}

/// The naming rule of a lock, as the engine and `semel-swift prepare` spell it
/// (`DependencyLock.lockPath(forDependencyAt:)`), on paths.
public enum LockedFolder {

    /// `Dependencies/GRDB.swift.semel-lock` for `Dependencies/GRDB.swift`.
    public static func lockPath(of folder: Path) -> Path {
        Path(DependencyLock.lockPath(forDependencyAt: folder.string))
    }

    /// The folder a lock at `path` locks, when the path is a lock's.
    public static func folder(lockedBy path: Path) -> Path? {
        let suffix = ".\(DependencyLock.fileExtension)"
        guard let name = path.lastComponent, name.hasSuffix(suffix), name.count > suffix.count else {
            return nil
        }
        return Path(segments: path.segments.dropLast()) / String(name.dropLast(suffix.count))
    }
}

/// A plan that mirrors the watched folders: its commands, and what the launch line says
/// of the comparison with the graph.
public struct MirrorPlan: Equatable {
    public let commands: [WatchCommand]
    /// How many paths the graph held and the disk lacks are removed: files, and folders
    /// that held nothing.
    public let removedCount: Int
    /// How many the graph held and the disk lacks are left, because the filter excepts
    /// them: a narrowing filter is not a request to delete what it narrows away.
    public let exceptedCount: Int
}

/// Reads a batch against the disk and says what to issue.
///
/// From the disk, not from what the stream said happened: FSEvents coalesces its flags and
/// may deliver them stale, and a save through a temporary file and a rename reports a
/// creation, a modification and a removal for paths whose end state is simply "there".
/// So a path that exists is pushed, one that does not is removed, and a folder that exists
/// is pushed whole — a folder moved into the tree is reported as the folder alone.
///
/// A folder that went is one `rm` of the highest folder that went with it, which takes
/// everything below it; a removal of something the graph never held — an editor's
/// temporary file that came and went inside one quiet interval — is no command at all.
public struct BatchPlanner {

    public let filter: WatchFilter

    public init(filter: WatchFilter) {
        self.filter = filter
    }

    /// The commands for `batch`: the removals, then the pushes, each in path order and
    /// none covered by another — no push of a file inside a folder pushed whole, no
    /// removal inside a folder removed.
    public func plan(_ batch: ChangeBatch, disk: some FileWildcardMatcherInput,
                     holdings: some InputHoldings) throws -> [WatchCommand] {
        // A rescanned path is planned as a changed one is: a folder on disk is pushed whole
        // either way, which is what a subtree whose changes were lost needs.
        var planning = Planning(filter: filter, disk: CachedListing(disk), holdings: holdings)
        for path in batch.rescanned + batch.changed {
            for target in targets(of: path) {
                try planning.planChange(target)
            }
        }
        return planning.commands
    }

    /// What mirroring the watched folders comes to, with `batch` planned beside it: the
    /// initial batch, and a batch reissued after a reconnection. Every path the graph holds
    /// below one of `folders` that the disk lacks is removed — the removals a push never
    /// makes, since a push only adds — and then every watched root is pushed.
    ///
    /// The comparison is with what a push would push: the lister's rule, then the filter,
    /// a dot-named file counting as admitted because the graph holds it. A held path the
    /// filter excepts is left, and counted, so a watcher started with a narrower filter
    /// than the last never deletes what it was told to ignore; a folder holding one is
    /// removed path by path around it rather than whole. Only `folders` are compared: a
    /// source the follow pushed from outside them is watched, but what the graph holds of
    /// it is not this watcher's to delete.
    public func planMirroring(_ batch: ChangeBatch = ChangeBatch(), folders: [Path],
                              disk: some FileWildcardMatcherInput,
                              holdings: some InputHoldings) throws -> MirrorPlan {
        var planning = Planning(filter: filter, disk: CachedListing(disk), holdings: holdings)
        let compared = Set(folders.filter { folder in !folders.contains { $0 != folder && folder.hasPrefix($0) } })
        for folder in compared.sorted(by: Path.precedes) {
            try planning.mirror(folder)
        }
        // A compared root the disk lacks was decided by the comparison, which leaves what
        // the filter excepts; any other root is pushed, or removed as a vanished path is.
        for root in filter.roots where !compared.contains(where: { root.hasPrefix($0) })
                                    || WatchFilter.entry(at: root, on: planning.disk) != nil {
            try planning.plan(root)
        }
        for path in batch.rescanned + batch.changed {
            for target in targets(of: path) {
                try planning.planChange(target)
            }
        }
        return MirrorPlan(commands: planning.commands, removedCount: planning.removedCount,
                          exceptedCount: planning.exceptedCount)
    }

    /// The paths a reported path stands for: itself when it is watched, and otherwise the
    /// watched roots below it — a folder above them renamed or rescanned whole.
    private func targets(of path: Path) -> [Path] {
        filter.isWatched(path) ? [path] : filter.roots(atOrBelow: path)
    }
}

// MARK: - One plan

/// The state of one plan: what it has decided so far, and the disk it reads.
private struct Planning<Disk: FileWildcardMatcherInput, Holdings: InputHoldings> {
    /// A `var`, because a plan that meets a change to a lock unlocks that lock's folder for
    /// the rest of the plan (B-146).
    var filter: WatchFilter
    let disk: Disk
    let holdings: Holdings

    private var pushes:  Set<Path> = []
    private var folders: Set<Path> = []
    private var removes: Set<Path> = []

    private(set) var removedCount  = 0
    private(set) var exceptedCount = 0

    init(filter: WatchFilter, disk: Disk, holdings: Holdings) {
        self.filter   = filter
        self.disk     = disk
        self.holdings = holdings
    }

    /// Decides one path the stream reported changed, as `plan` does, and — when it is the
    /// lock of a locked folder the filter leaves alone — that folder with it (B-146). A
    /// lock that changed, came or went is how a locked folder changes: `prepare` writes the
    /// copy and the lock together, so the folder is mirrored and pushed in the lock's batch
    /// and the barrier at `commit` sees the two together. Only for a reported change: a
    /// mirror of everything reaches every lock, and pushing every locked folder with it
    /// would send a copy edited by hand along with the rest and have the whole launch
    /// refused.
    mutating func planChange(_ path: Path) throws {
        if let lockedFolder = LockedFolder.folder(lockedBy: path), filter.lockedAndNotWatched.contains(lockedFolder),
           !filter.isAlwaysExcepted(path), !WatchFilter.passesThroughDotFolder(path) {
            filter = filter.unlocking(lockedFolder)
            try mirror(lockedFolder)
            try plan(lockedFolder)
        }
        try plan(path)
    }

    /// Decides one path: a push when it exists — a folder whole — and a removal when it
    /// does not.
    mutating func plan(_ path: Path) throws {
        guard !filter.isAlwaysExcepted(path), !WatchFilter.passesThroughDotFolder(path) else {
            return
        }

        guard let entry = WatchFilter.entry(at: path, on: disk) else {
            try planRemoval(of: path)
            return
        }
        switch entry.kind {
        case .folder:
            try planFolder(path)
        case .file:
            try planFile(path)
        }
    }

    private mutating func planFile(_ path: Path) throws {
        let isHeld = try isDotNamed(path) && !filter.namesExactly(path) ? holdings.holds(path) : false
        if filter.admits(path, isHeld: isHeld) {
            pushes.insert(path)
        }
    }

    /// A folder on disk, pushed whole when everything in it is admitted — one `push`, which
    /// sends only what the graph lacks (B-132) — and file by file when the filter takes
    /// some of it. The base itself is planned by its children, because `push .` names
    /// nothing: the matcher has no segment to match.
    private mutating func planFolder(_ folder: Path) throws {
        guard folder.isEmpty || filter.mayAdmitBelow(folder) else {
            return
        }
        guard !folder.isEmpty else {
            for child in try disk.allFiles(inDirectoryPath: disk.rootDirectoryPath) {
                try plan(child.path)
            }
            return
        }
        // A locked folder below this one would go with a push of it whole, so this one is
        // planned by its children and the locked folder is left out.
        guard !filter.holdsLockedFolder(below: folder) else {
            let directory = (disk.rootDirectoryPath as NSString).appendingPathComponent(folder.string)
            for child in try disk.allFiles(inDirectoryPath: directory) {
                try plan(folder / child.path)
            }
            return
        }
        guard !filter.admitsEverything else {
            folders.insert(folder)
            return
        }
        let matcher = FileWildcardMatcher(input: disk)
        let files = try matcher.findAllMatching(pathOrWildcard: folder / Path(WildcardPath.anyFolders) / "*")
            .filter { $0.kind == .file && !filter.isAlwaysExcepted($0.path) }
            .map(\.path)
        let admitted = files.filter { filter.admits($0) }
        if admitted.count == files.count {
            folders.insert(folder)
        } else {
            pushes.formUnion(admitted)
        }
    }

    /// A path the disk no longer has: the highest folder that went with it, below its
    /// watched root, is what vanished, and it is removed when the graph holds it.
    private mutating func planRemoval(of path: Path) throws {
        let root = filter.root(of: path) ?? path
        var vanished = root
        if WatchFilter.entry(at: root, on: disk) != nil {
            vanished = path
            var candidate = root
            for segment in path.segments.dropFirst(root.count) {
                candidate = candidate / segment
                guard WatchFilter.entry(at: candidate, on: disk) != nil else {
                    vanished = candidate
                    break
                }
            }
        }
        // The base itself is never removed: it is where every push is read from.
        guard !vanished.isEmpty else {
            return
        }
        let concerned = vanished == path
            ? filter.admits(path, isHeld: true) || filter.mayAdmitBelow(path)
            : filter.mayAdmitBelow(vanished)
        guard concerned, try holdings.holds(vanished) else {
            return
        }
        removes.insert(vanished)
    }

    // MARK: - Mirroring a folder

    /// Compares what the graph holds below `folder` with the disk, and removes what the
    /// disk lacks and the filter admits: the highest such path, when everything held below
    /// it goes with it.
    mutating func mirror(_ folder: Path) throws {
        let held = try holdings.holdings(below: folder)
        let tree = HeldTree(held, below: folder)
        guard WatchFilter.entry(at: folder, on: disk) != nil else {
            // The whole watched folder went: compared when the graph holds it at all.
            guard !folder.isEmpty, try !held.isEmpty || holdings.holds(folder) else {
                return
            }
            if decideMissing(folder, in: tree) {
                removes.insert(folder)
            }
            return
        }
        compare(folder, in: tree)
    }

    /// A folder the disk has: each held child the disk lacks is decided, and each it has
    /// that is a folder is compared in turn.
    private mutating func compare(_ folder: Path, in tree: HeldTree) {
        for child in tree.children(of: folder) {
            guard WatchFilter.entry(at: child, on: disk) != nil else {
                if decideMissing(child, in: tree) {
                    removes.insert(child)
                }
                continue
            }
            if tree.isFolder(child) {
                compare(child, in: tree)
            }
        }
    }

    /// Whether a held path the disk lacks goes whole. A file goes when the filter admits
    /// it; an empty folder when the filter could admit something below it; any other
    /// folder when everything held below it goes — and when not, what goes below it is
    /// removed on its own and the rest stays. Below a missing path everything is missing,
    /// so the disk is not asked again.
    private mutating func decideMissing(_ path: Path, in tree: HeldTree) -> Bool {
        guard tree.isFolder(path) else {
            return count(removing: filter.admits(path, isHeld: true))
        }
        let below = tree.children(of: path)
        guard !below.isEmpty else {
            return count(removing: filter.mayAdmitBelow(path))
        }
        var goingWhole: [Path] = []
        for child in below where decideMissing(child, in: tree) {
            goingWhole.append(child)
        }
        guard goingWhole.count == below.count else {
            removes.formUnion(goingWhole)
            return false
        }
        return true
    }

    /// Counts one held file, or empty folder, the disk lacks: removed, or excepted.
    private mutating func count(removing: Bool) -> Bool {
        if removing {
            removedCount += 1
        } else {
            exceptedCount += 1
        }
        return removing
    }

    private func isDotNamed(_ path: Path) -> Bool {
        path.lastComponent?.hasPrefix(".") == true
    }

    /// Removals first, then pushes: a rename is a removal and a push, and a reader of the
    /// transcript sees the old name go before the new one arrives.
    var commands: [WatchCommand] {
        let removed = removes.filter { path in !removes.contains { $0 != path && path.hasPrefix($0) } }
        let pushedFolders = folders.filter { path in !folders.contains { $0 != path && path.hasPrefix($0) } }
        let pushedFiles = pushes.filter { path in !pushedFolders.contains { path.hasPrefix($0) } }
        return removed.sorted(by: Path.precedes).map(WatchCommand.remove)
             + pushedFolders.union(pushedFiles).sorted(by: Path.precedes).map(WatchCommand.push)
    }
}

// MARK: - What the graph holds below a folder

/// What the graph holds below a mirrored folder, as a tree: each folder's held children,
/// and which paths are folders — a held file's parent is one whether or not the listing
/// named it.
private struct HeldTree {
    private var childrenByFolder: [Path: Set<Path>] = [:]
    private var folders: Set<Path> = []

    init(_ held: [FileWildcardEntry], below root: Path) {
        folders.insert(root)
        for entry in held {
            if entry.kind == .folder {
                folders.insert(entry.path)
            }
            var child = entry.path
            while child.count > root.count {
                let parent = Path(segments: child.segments.dropLast())
                childrenByFolder[parent, default: []].insert(child)
                folders.insert(parent)
                child = parent
            }
        }
    }

    func children(of folder: Path) -> [Path] {
        (childrenByFolder[folder] ?? []).sorted(by: Path.precedes)
    }

    func isFolder(_ path: Path) -> Bool {
        folders.contains(path)
    }
}

// MARK: - A listing read once per plan

/// The disk, with each folder listed once for the length of one plan: a `git checkout`
/// reports hundreds of paths in a handful of folders, and each path is looked up through
/// every folder above it.
private final class CachedListing<Disk: FileWildcardMatcherInput>: FileWildcardMatcherInput {
    private let disk: Disk
    private var listings: [String: [FileWildcardEntry]] = [:]

    init(_ disk: Disk) {
        self.disk = disk
    }

    var rootDirectoryPath: String { disk.rootDirectoryPath }

    func allFiles(inDirectoryPath path: String) throws -> [FileWildcardEntry] {
        if let listed = listings[path] {
            return listed
        }
        let listed = try disk.allFiles(inDirectoryPath: path)
        listings[path] = listed
        return listed
    }

    func hiddenFile(named name: String, inDirectoryPath path: String) -> FileWildcardEntry? {
        disk.hiddenFile(named: name, inDirectoryPath: path)
    }
}
