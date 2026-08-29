// FileWildcardMatcher.swift
// build_system

import Foundation
import SemelNodeKit

public enum FileWildcardEntryKind {
    case file
    case folder
}

public struct FileWildcardEntry {
    public let path: Path                // logical path relative to the file-system root
    public let kind: FileWildcardEntryKind
    public let isMissing: Bool
    public let isUnreferenced: Bool
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

    /// Find all files and folders matching a glob pattern.
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
        guard segmentIndex < segments.count else { return }

        let segment = segments[segmentIndex]
        let isLastSegment = segmentIndex == segments.count - 1

        // ── ** (globstar) ──────────────────────────────────────────
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
            guard segmentMatches(pattern: segment, name: child.path.string) else { continue }

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

    // MARK: - Segment-level glob matching

    /// Internal rather than private so the segment matcher can be tested directly. Driving
    /// it through directory listings costs a mock filesystem per case, which is why the
    /// backtracking it exists for went untested for so long.
    func segmentMatches(pattern: String, name: String) -> Bool {
        segmentMatches(pattern: Array(pattern.unicodeScalars),
                       name:    Array(name.unicodeScalars))
    }

    /// Matches one path segment against a pattern containing `*` and `?`.
    ///
    /// Walks both strings once, remembering the most recent `*` so it can come back to it.
    /// When the rest of the pattern hits a dead end, that `*` is given one more character and
    /// the walk resumes — which is what makes `*.swift` match `a.b.swift`, where the first
    /// attempt commits the `*` to the wrong dot.
    ///
    /// Only the most recent `*` needs remembering. An earlier one can always hand its work to
    /// a later one, so backtracking further can never find a match this one could not.
    private func segmentMatches(pattern: [Unicode.Scalar], name: [Unicode.Scalar]) -> Bool {
        var patternIndex = 0
        var nameIndex    = 0

        // Where to resume when an attempt fails: the pattern position just after the most
        // recent `*`, and how much of the name that `*` has been given so far. Nil until a
        // `*` has been seen, which is what makes a mismatch final rather than retried.
        var afterLastStar:  Int? = nil
        var nameAtLastStar: Int  = 0

        while nameIndex < name.count {
            if patternIndex < pattern.count,
               pattern[patternIndex] == "?" || pattern[patternIndex] == name[nameIndex] {
                patternIndex += 1
                nameIndex    += 1

            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                // Start by letting this `*` match nothing, and note where to come back to.
                afterLastStar  = patternIndex + 1
                nameAtLastStar = nameIndex
                patternIndex  += 1

            } else if let afterLastStar {
                // Dead end — give the most recent `*` one more character and resume after it.
                nameAtLastStar += 1
                nameIndex       = nameAtLastStar
                patternIndex    = afterLastStar

            } else {
                return false        // mismatch, and no `*` to fall back on
            }
        }

        // The name is used up; the pattern matches only if what is left of it is all `*`.
        return pattern[patternIndex...].allSatisfy { $0 == "*" }
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
        guard let children = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return children.compactMap { name -> FileWildcardEntry? in
            guard !name.hasPrefix(".") else { return nil }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { return nil }
            return FileWildcardEntry(path: Path(name),
                                     kind: isDir.boolValue ? .folder : .file,
                                     isMissing: false, isUnreferenced: false)
        }.sorted { $0.path.string < $1.path.string }
    }
}

// MARK: - InternalFileSystemLister

public final class InternalFileSystemLister: FileWildcardMatcherInput {
    public let rootDirectoryPath = "/"
    let folder: Node

    public init(folder: Node) {
        self.folder = folder
    }

    public func allFiles(inDirectoryPath: String) throws -> [FileWildcardEntry] {
        guard let start = try folder.childNode(path: inDirectoryPath) else {
            throw NodeError.other(message: "No such directory: \(inDirectoryPath)")
        }

        return try start.allChildren.map { node in
            switch node.kind {

            case Folder.kind:
                guard let folder = try node.nodeFunction() as? Folder else {
                    assert(false)
                    throw NodeError.other(message: "Unexpected object kind")
                }
                let isOutputFileSystem = try folder.thisNode
                    .buildFullPathName(baseNodeID: nil)
                    .firstComponent == Folder.outputFileSystemName
                return FileWildcardEntry(path: Path(node.name!),
                                         kind: .folder,
                                         isMissing: isOutputFileSystem ? false : try !folder.isPinned,
                                         isUnreferenced: try folder.hasNoOutputWires() && node.allChildren.isEmpty)

            default:
                let nodeFunction = try node.nodeFunction()
                guard let pinnable = nodeFunction as? Pinnable else {
                    assert(false)
                    throw NodeError.other(message: "Unexpected object kind")
                }
                return FileWildcardEntry(path: Path(node.name!),
                                         kind: .file,
                                         isMissing: try !pinnable.isPinned,
                                         isUnreferenced: try nodeFunction.hasNoOutputWires())
            }
        }
    }
}
