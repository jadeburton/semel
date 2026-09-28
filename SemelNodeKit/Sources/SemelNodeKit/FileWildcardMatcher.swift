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

    public init(path: Path, kind: FileWildcardEntryKind, state: FileWildcardEntryState?, isUnreferenced: Bool) {
        self.path = path
        self.kind = kind
        self.state = state
        self.isUnreferenced = isUnreferenced
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
                                                     isUnreferenced: child.isUnreferenced))
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
                                                 isUnreferenced: child.isUnreferenced))
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
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: path) else {
            return []
        }
        let realDirectory = (path as NSString).resolvingSymlinksInPath
        return children.compactMap { name -> FileWildcardEntry? in
            guard !name.hasPrefix(".") else {
                return nil
            }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else {
                return nil
            }
            // A symbolic link into a folder above this one is a cycle: following it
            // would walk the same tree without end, growing until memory ran out. A link
            // elsewhere is followed, since a package may keep sources behind one.
            if isDir.boolValue, Self.isSymbolicLink(fullPath) {
                let realChild = (fullPath as NSString).resolvingSymlinksInPath
                if realDirectory == realChild || realDirectory.hasPrefix(realChild + "/") {
                    return nil
                }
            }
            // A directory entry on disk is the whole story: there is no port behind it to
            // ask, so this lister has no state to report and says so.
            return FileWildcardEntry(path: Path(name),
                                     kind: isDir.boolValue ? .folder : .file,
                                     state: nil, isUnreferenced: false)
        }.sorted { $0.path.string < $1.path.string }
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }
}
