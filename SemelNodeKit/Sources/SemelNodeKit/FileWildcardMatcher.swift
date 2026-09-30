// FileWildcardMatcher.swift
// SemelNodeKit

import Foundation

public enum FileWildcardEntryKind {
    case file
    case folder
}

/// What the graph says about the name an entry stands for: whether the node behind it is
/// carrying a value, and when it is not, which of the port's reasons stands there.
///
/// One case per state a reader can act on differently. A source that was taken away
/// settles by itself once the collector reaches it; a product whose input failed is a
/// failure to act on; a name nothing has produced anything for is neither, and a graph
/// full of fresh nodes is not a graph full of failures. Folding them onto one word tells
/// the reader nothing.
public enum FileWildcardEntryState: Equatable, Sendable {
    /// The node carries a value: a pushed source, or a product that built.
    case present
    /// A value is on its way, and a reader may wait for it.
    case pending
    /// Nothing has ever produced a value here: a source nobody pushed, a folder nobody
    /// pushed into, or a product whose input is in one of those states.
    case notProduced
    /// A source that was pushed and then removed. The node stands while something still
    /// names it, and goes when the collector reaches it.
    case deleted
    /// The node failed, or something it reads did.
    case failed
}

extension FileWildcardEntryState {
    /// Read by case, never by message text: a reason carrying a sentence is the node's own
    /// failure, and every other reason is its own case precisely so that a reader deciding
    /// what to say asks which case it is.
    public init(_ value: NodeValue) {
        switch value {
        case .value:
            self = .present
        case .noValue(let reason):
            switch reason {
            case .pending:                         self = .pending
            case .initializing, .inputNotProduced: self = .notProduced
            case .deleted:                         self = .deleted
            case .inputInError, .error:            self = .failed
            }
        }
    }
}

public struct FileWildcardEntry {
    public let path: Path                // logical path relative to the file-system root
    public let kind: FileWildcardEntryKind
    /// What the graph says about this name, or `nil` from a lister with no graph behind it.
    public let state: FileWildcardEntryState?
    public let isUnreferenced: Bool
    /// For an entry that is a symbolic link pushed as one, what the link holds: relative to
    /// its folder, as it reads. Only `ExternalFileSystemLister` says so, and only for a link
    /// that stays inside its own folder (`isContained(symbolicLinkTarget:)`) — the links a
    /// bundle holds (B-77). The entry is still the file or folder the link names, walked
    /// as one, so that everything reading a file or walking a folder through the link reads
    /// what it did when a push followed every link; the target is what the fold, a tree and
    /// the export read instead.
    public let symbolicLinkTarget: String?

    public init(path: Path, kind: FileWildcardEntryKind, state: FileWildcardEntryState?, isUnreferenced: Bool,
                symbolicLinkTarget: String? = nil) {
        self.path = path
        self.kind = kind
        self.state = state
        self.isUnreferenced = isUnreferenced
        self.symbolicLinkTarget = symbolicLinkTarget
    }
}

public protocol FileWildcardMatcherInput {
    var rootDirectoryPath: String { get }   // real filesystem path (String for Foundation APIs)
    func allFiles(inDirectoryPath: String) throws -> [FileWildcardEntry]
}

// MARK: - FileWildcardMatcher

public final class FileWildcardMatcher {
    private let input: any FileWildcardMatcherInput

    public init(input: some FileWildcardMatcherInput) {
        self.input = input
    }

    /// Find all files and folders matching a wildcard pattern.
    ///
    /// Supports:
    /// - `?`  — matches any single character
    /// - `*`  — matches zero or more characters within a single path segment
    /// - `**` — matches zero or more directory levels (recursive)
    public func findAllMatching(pathOrWildcard: Path) throws -> [FileWildcardEntry] {
        var results: [FileWildcardEntry] = []
        try matchSegments(
            segments: pathOrWildcard.segments,
            segmentIndex: 0,
            currentDirectory: input.rootDirectoryPath,
            currentLogicalPath: .empty,
            results: &results
        )
        return results
    }

    /// Convenience overload accepting a String pattern.
    public func findAllMatching(pathOrWildcard: String) throws -> [FileWildcardEntry] {
        try findAllMatching(pathOrWildcard: Path(pathOrWildcard))
    }

    // MARK: - Private recursive matcher

    private func matchSegments(
        segments: [String],
        segmentIndex: Int,
        currentDirectory: String,
        currentLogicalPath: Path,
        results: inout [FileWildcardEntry]
    ) throws {
        guard segmentIndex < segments.count else {
            return
        }

        let segment = segments[segmentIndex]
        let isLastSegment = segmentIndex == segments.count - 1

        // ── ** (doubleStar) ──────────────────────────────────────────
        // The same meaning as in a formula (`WildcardPath`): zero or more folders, and as
        // the last segment every entry below, at any depth.
        if segment == WildcardPath.anyFolders {
            // ** can match zero directories (skip it) …
            try matchSegments(segments: segments, segmentIndex: segmentIndex + 1,
                              currentDirectory: currentDirectory,
                              currentLogicalPath: currentLogicalPath, results: &results)

            // … or one-or-more directories (recurse into each child dir).
            let children = try input.allFiles(inDirectoryPath: currentDirectory)

            for child in children {
                let childLogicalPath  = currentLogicalPath / child.path
                if isLastSegment {
                    results.append(FileWildcardEntry(path: childLogicalPath, kind: child.kind,
                                                     state: child.state,
                                                     isUnreferenced: child.isUnreferenced,
                                                     symbolicLinkTarget: child.symbolicLinkTarget))
                }
                guard child.kind == .folder else {
                    continue
                }
                let childPhysicalPath = (currentDirectory as NSString).appendingPathComponent(child.path.string)

                try matchSegments(segments: segments, segmentIndex: segmentIndex,
                                  currentDirectory: childPhysicalPath,
                                  currentLogicalPath: childLogicalPath, results: &results)
            }

            return
        }

        // ── Normal or single-star segment ─────────────────────────
        let children = try input.allFiles(inDirectoryPath: currentDirectory)

        for child in children {
            guard WildcardSegment.matches(pattern: segment, name: child.path.string) else {
                continue
            }

            let childLogicalPath = currentLogicalPath / child.path

            if isLastSegment {
                results.append(FileWildcardEntry(path: childLogicalPath, kind: child.kind,
                                                 state: child.state,
                                                 isUnreferenced: child.isUnreferenced,
                                                 symbolicLinkTarget: child.symbolicLinkTarget))
            } else if child.kind == .folder {
                let childPhysicalPath = (currentDirectory as NSString).appendingPathComponent(child.path.string)
                try matchSegments(segments: segments, segmentIndex: segmentIndex + 1,
                                  currentDirectory: childPhysicalPath,
                                  currentLogicalPath: childLogicalPath, results: &results)
            }
        }
    }
}

// MARK: - ExternalFileSystemLister

public final class ExternalFileSystemLister: FileWildcardMatcherInput {
    public let rootDirectoryPath: String

    public init(rootDirectoryPath: String) {
        self.rootDirectoryPath = rootDirectoryPath
    }

    public func allFiles(inDirectoryPath path: String) -> [FileWildcardEntry] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(atPath: path) else {
            return []
        }
        let realDirectory = (path as NSString).resolvingSymlinksInPath
        return children.compactMap { name -> FileWildcardEntry? in
            guard !name.hasPrefix(".") else {
                return nil
            }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            // Followed: a link to nothing, or a loop of links, is left out as a missing
            // file is.
            guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
                return nil
            }
            // A directory entry on disk is the whole story: there is no port behind it to
            // ask, so this lister has no state to report and says so.
            let kind: FileWildcardEntryKind = isDirectory.boolValue ? .folder : .file
            guard let linkTarget = Self.symbolicLinkTarget(at: fullPath) else {
                return FileWildcardEntry(path: Path(name), kind: kind, state: nil, isUnreferenced: false)
            }
            // A link that stays inside its own folder is pushed as the link it is, as well
            // as walked: what a bundle holds, `Versions/Current -> A` (B-77). It names
            // something below its own folder, so it is never a cycle.
            if Self.isContained(symbolicLinkTarget: linkTarget) {
                return FileWildcardEntry(path: Path(name), kind: kind, state: nil, isUnreferenced: false,
                                         symbolicLinkTarget: linkTarget)
            }
            // A symbolic link into a folder above this one is a cycle: following it
            // would walk the same tree without end, growing until memory ran out. A link
            // elsewhere is followed, since a package may keep sources behind one.
            if isDirectory.boolValue {
                let realChild = (fullPath as NSString).resolvingSymlinksInPath
                if realDirectory == realChild || realDirectory.hasPrefix(realChild + "/") {
                    return nil
                }
            }
            return FileWildcardEntry(path: Path(name), kind: kind, state: nil, isUnreferenced: false)
        }.sorted { $0.path.string < $1.path.string }
    }

    /// What the link at `path` holds, or nil when `path` is not a link. `lstat` rather than
    /// `attributesOfItem`, which reads every attribute of every entry a push lists to
    /// answer this one question.
    private static func symbolicLinkTarget(at path: String) -> String? {
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFLNK else {
            return nil
        }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    /// Whether a link holding `target` stays inside the folder that holds it: relative,
    /// never climbing above that folder with `..`, naming no dot-named component — which a
    /// push leaves out, so the link would name nothing pushed — and naming something below
    /// the folder rather than the folder itself.
    ///
    /// About the link's own folder and not the folder a push was asked for, so that it
    /// reads the same from any root: `prepare` folds `Dependencies/Sparkle` on disk, the
    /// engine folds it inside a push of the whole clone, and the two roots are equal only
    /// if both decide each link alike (B-06). A link inside its own folder is inside every
    /// folder that holds it.
    public static func isContained(symbolicLinkTarget target: String) -> Bool {
        guard !target.hasPrefix("/") else {
            return false
        }
        var depth = 0
        for component in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                depth -= 1
                guard depth >= 0 else {
                    return false
                }
            default:
                guard !component.hasPrefix(".") else {
                    return false
                }
                depth += 1
            }
        }
        return depth > 0
    }
}

// MARK: - What a push sends

/// What a push sends for one file `ExternalFileSystemLister` listed: the bytes a reader of
/// the path gets, the mode, and for a link its target. Shared by the client, which sends
/// it, and by anything that has to push exactly as the client does — a test comparing the
/// engine's fold with `prepare`'s.
public struct PushedContent {
    public let bytes: Data
    public let mode: UInt16
    /// The link's target, for a file that is a symbolic link pushed as one.
    public let symbolicLinkTarget: String?

    /// Read from `absolutePath` on disk, links followed: a link's bytes and mode are the
    /// file's it names, so that what reads the pushed file's bytes reads what it read when
    /// a push followed every link.
    public init(ofFileAt absolutePath: String, listedAs entry: FileWildcardEntry) throws {
        bytes = try Data(contentsOf: URL(fileURLWithPath: absolutePath))
        mode  = Self.mode(ofFileAt: absolutePath)
        symbolicLinkTarget = entry.symbolicLinkTarget
    }

    /// The file's permission bits, links followed, or the default when they cannot be read.
    /// Public for the fold on disk, whose file lines carry the mode a push sends (B-132).
    ///
    /// `stat` rather than `FileManager`: it follows links itself, where resolving the path
    /// first cost an `lstat` per component, and a push of a tree asks this of every file.
    /// The bits are the ones `FileManager` reports as `posixPermissions`.
    public static func mode(ofFileAt absolutePath: String) -> UInt16 {
        var status = stat()
        guard stat(absolutePath, &status) == 0 else {
            return FileMetadata.defaultMode
        }
        return UInt16(truncatingIfNeeded: status.st_mode & 0o7777)
    }
}
