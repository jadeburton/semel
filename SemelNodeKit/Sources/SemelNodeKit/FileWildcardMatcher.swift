// FileWildcardMatcher.swift
// SemelNodeKit

import Foundation

public enum FileWildcardEntryKind {
    case file
    case folder
}

public struct FileWildcardEntry {
    public let path: Path                // logical path relative to the file-system root
    public let kind: FileWildcardEntryKind
    public let isMissing: Bool
    public let isUnreferenced: Bool

    public init(path: Path, kind: FileWildcardEntryKind, isMissing: Bool, isUnreferenced: Bool) {
        self.path = path
        self.kind = kind
        self.isMissing = isMissing
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
        if segment == "**" {
            // ** can match zero directories (skip it) …
            try matchSegments(segments: segments, segmentIndex: segmentIndex + 1,
                              currentDirectory: currentDirectory,
                              currentLogicalPath: currentLogicalPath, results: &results)

            // … or one-or-more directories (recurse into each child dir).
            let children = try input.allFiles(inDirectoryPath: currentDirectory)

            for child in children where child.kind == .folder {
                let childLogicalPath  = currentLogicalPath / child.path
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
                                                 isMissing: child.isMissing,
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
        return children.compactMap { name -> FileWildcardEntry? in
            guard !name.hasPrefix(".") else {
                return nil
            }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else {
                return nil
            }
            return FileWildcardEntry(path: Path(name),
                                     kind: isDir.boolValue ? .folder : .file,
                                     isMissing: false, isUnreferenced: false)
        }.sorted { $0.path.string < $1.path.string }
    }
}
