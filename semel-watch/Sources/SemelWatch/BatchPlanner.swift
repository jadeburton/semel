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
/// it was pushed by its name. The interpreter in `semel-watch`; a set in a test.
public protocol InputHoldings {
    func holds(_ path: Path) throws -> Bool
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
                try planning.plan(target)
            }
        }
        return planning.commands
    }

    /// What a push of every watched root comes to: the initial push, and the full push
    /// after a reconnection. A root no longer on disk is removed, as any vanished path is.
    public func planEverything(disk: some FileWildcardMatcherInput,
                               holdings: some InputHoldings) throws -> [WatchCommand] {
        try plan(ChangeBatch(rescanned: filter.roots), disk: disk, holdings: holdings)
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
    let filter: WatchFilter
    let disk: Disk
    let holdings: Holdings

    private var pushes:  Set<Path> = []
    private var folders: Set<Path> = []
    private var removes: Set<Path> = []

    init(filter: WatchFilter, disk: Disk, holdings: Holdings) {
        self.filter   = filter
        self.disk     = disk
        self.holdings = holdings
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
