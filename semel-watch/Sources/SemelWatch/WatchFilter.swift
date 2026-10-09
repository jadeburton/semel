// WatchFilter.swift
// SemelWatch
//
// Which changed paths a watcher pushes (B-126). The set it starts from is the set a push
// would push — `ExternalFileSystemLister`'s rule, asked through `entry(at:on:)` — and the
// filter only narrows it: `--only` and `--except`, spelled as a formula's for-each spells
// its items and its `except` (B-123), the folders nothing ever pushes, and the folders a
// lock in `input:` locks (B-146).

import Foundation
import SemelNodeKit

public struct WatchFilter: Equatable {

    /// What `--only` is when none is given: every path below the base.
    public static let everything = "**/*"

    /// Where `build` exports when it is not told where (`CommandInterpreter
    /// .defaultExportFolder`), relative to the base. Spelled here rather than read from
    /// there, so that this library sees nothing of the interpreter but what it drives; the
    /// two are compared in a test.
    public static let defaultExportFolder = Path("semel-out")

    /// The watched paths, relative to the base: the folders named at launch — the empty
    /// path is the base itself — and any file a formula's follow pushed from outside them.
    public private(set) var roots: [Path]

    /// The `--only` patterns, as segments; `everything` when none was given.
    public let only: [Path]

    /// The `--except` patterns, as segments.
    public let except: [Path]

    /// Folders never pushed, whatever the flags say: the export destination when it lies
    /// under the base, because a watcher that pushed what it exported would build forever,
    /// and `semel-out`, where `build` exports when it is not told where.
    public let alwaysExcepted: [Path]

    /// The folders a lock beside them in `input:` locks (B-146), as the graph last said.
    /// Not watched unless an `--only` names one: a locked folder changes by an action that
    /// brings its lock — `semel-swift prepare` — and an edit under one that the watcher
    /// pushed would be refused at `commit` every time. A change to a lock is how such a
    /// folder's change arrives, and the planner pushes the folder with it.
    public private(set) var locked: [Path] = []

    public init(roots: [Path], only: [String] = [], except: [String] = [], exportDestination: Path? = nil) {
        self.roots  = roots
        self.only   = (only.isEmpty ? [Self.everything] : only).map { Path($0) }
        self.except = except.map { Path($0) }
        var alwaysExcepted = [Self.defaultExportFolder]
        if let exportDestination, !exportDestination.isEmpty, exportDestination != Self.defaultExportFolder {
            alwaysExcepted.append(exportDestination)
        }
        self.alwaysExcepted = alwaysExcepted
    }

    /// Adds a path to what is watched: a source the follow of a formula's inputs pushed
    /// from outside the watched folders, which a later change to must reach the graph as
    /// the rest of the tree does — or the watcher and the push would disagree about it.
    public mutating func watch(_ path: Path) {
        guard !isWatched(path) else {
            return
        }
        roots.append(path)
    }

    /// Replaces what the filter knows of the locked folders.
    public mutating func setLocked(_ folders: [Path]) {
        locked = folders.sorted(by: Path.precedes)
    }

    /// The locked folders this filter leaves alone: every one no `--only` names.
    public var lockedAndNotWatched: [Path] {
        locked.filter { !namesLockedFolder($0) }
    }

    /// Whether an `--only` names `folder` itself: its literal segments, before any
    /// wildcard, reach down to the folder — `--only 'Dependencies/GRDB.swift/**/*'`. The
    /// default `--only` names nothing, so a locked folder is left alone by default.
    public func namesLockedFolder(_ folder: Path) -> Bool {
        guard only != [Path(Self.everything)] else {
            return false
        }
        return only.contains { pattern in
            let literal = pattern.segments.prefix { !$0.contains("*") && !$0.contains("?") }
            return literal.count >= folder.count && Array(literal.prefix(folder.count)) == folder.segments
        }
    }

    /// Whether `path` is or lies below a locked folder the filter leaves alone.
    public func isInLockedFolder(_ path: Path) -> Bool {
        lockedAndNotWatched.contains { path.hasPrefix($0) }
    }

    /// Whether a locked folder the filter leaves alone lies strictly below `folder`, so
    /// that a push of the folder whole would send it.
    public func holdsLockedFolder(below folder: Path) -> Bool {
        lockedAndNotWatched.contains { $0 != folder && $0.hasPrefix(folder) }
    }

    /// The filter with `folder` no longer locked: what a plan uses for a folder whose lock
    /// changed in the batch, which is pushed whole with its lock.
    func unlocking(_ folder: Path) -> WatchFilter {
        var unlocked = self
        unlocked.locked.removeAll { $0 == folder }
        return unlocked
    }

    // MARK: - Questions about a path

    /// Whether `path` is a watched root or lies below one.
    public func isWatched(_ path: Path) -> Bool {
        roots.contains { path.hasPrefix($0) }
    }

    /// The watched roots at or below `path`: what a change reported for a folder above
    /// them — renamed away, or rescanned whole — comes to.
    public func roots(atOrBelow path: Path) -> [Path] {
        roots.filter { $0.hasPrefix(path) }
    }

    /// The watched root `path` lies under, the deepest when roots nest.
    public func root(of path: Path) -> Path? {
        roots.filter { path.hasPrefix($0) }.max { $0.count < $1.count }
    }

    /// Whether `path` is or lies below a folder nothing ever pushes.
    public func isAlwaysExcepted(_ path: Path) -> Bool {
        alwaysExcepted.contains { path.hasPrefix($0) }
    }

    /// Whether a folder on the way to `path` is dot-named. The lister never walks into
    /// one — a checkout's `.git`, an editor's `.swiftpm` — so nothing below it is ever a
    /// candidate, however it is named.
    public static func passesThroughDotFolder(_ path: Path) -> Bool {
        path.segments.dropLast().contains { $0.hasPrefix(".") }
    }

    /// Whether `--only` and `--except` let `path` through, before any question of what is
    /// on disk: some `--only` matches it and no `--except` does, it is watched, and it is
    /// not where exports go.
    ///
    /// A dot-named file is matched by no wildcard, as `push` matches none (B-77 item 5):
    /// only by an `--only` naming it exactly, or — `isHeld` — because the graph holds it
    /// already, pushed by its name, so a change to it is a change to a source.
    public func admits(_ path: Path, isHeld: Bool = false) -> Bool {
        guard let name = path.lastComponent, isWatched(path), !isAlwaysExcepted(path),
              !Self.passesThroughDotFolder(path), !isInLockedFolder(path) else {
            return false
        }
        let selected: Bool
        if name.hasPrefix(".") && !isHeld {
            selected = namesExactly(path)
        } else {
            selected = only.contains { WildcardPath.matches(pattern: $0.segments, path: path.segments) }
        }
        return selected && !except.contains { WildcardPath.matches(pattern: $0.segments, path: path.segments) }
    }

    /// Whether some `--only` names `path`'s last segment literally and matches the rest:
    /// `--only app/.all-contributorsrc`, `--only '**/.swiftlint.yml'`.
    public func namesExactly(_ path: Path) -> Bool {
        only.contains { pattern in
            guard let last = pattern.lastComponent, !last.contains(where: { $0 == "*" || $0 == "?" }),
                  last == path.lastComponent else {
                return false
            }
            return WildcardPath.matches(pattern: pattern.segments, path: path.segments)
        }
    }

    /// Whether anything below the folder `folder` could be admitted: the walk's question,
    /// asked before the folder is listed. An `--except` cannot be decided here, since it
    /// may take some of what is below and leave the rest.
    public func mayAdmitBelow(_ folder: Path) -> Bool {
        guard !isAlwaysExcepted(folder), !folder.segments.contains(where: { $0.hasPrefix(".") }),
              !isInLockedFolder(folder) else {
            return false
        }
        guard isWatched(folder) || !roots(atOrBelow: folder).isEmpty else {
            return false
        }
        return only.contains { WildcardPath.canMatchBelow(pattern: $0.segments, folder: folder.segments) }
    }

    /// Whether every file the lister lists is admitted, so that a folder is pushed whole by
    /// one `push <folder>` rather than file by file. The folders always excepted do not
    /// spoil it: the interpreter's push leaves those out on its own.
    public var admitsEverything: Bool {
        only == [Path(Self.everything)] && except.isEmpty
    }

    // MARK: - What is on disk

    /// The entry the lister gives for `path` exactly, or nil when a push of `path` would
    /// find nothing: missing, under a dot-named folder, a link the lister leaves out
    /// because it points above itself. A dot-named file named exactly is found, as `push`
    /// finds one; whether it is a candidate is `admits`' question.
    public static func entry(at path: Path, on disk: some FileWildcardMatcherInput) -> FileWildcardEntry? {
        guard !path.isEmpty else {
            return FileWildcardEntry(path: path, kind: .folder, state: nil, isUnreferenced: false)
        }
        let matcher = FileWildcardMatcher(input: disk)
        // The path is literal; a name holding `*` or `?` matches as a pattern, and the
        // exact one is picked out of what it matched.
        let matches = (try? matcher.findAllMatching(pathOrWildcard: path)) ?? []
        return matches.first { $0.path == path }
    }
}
