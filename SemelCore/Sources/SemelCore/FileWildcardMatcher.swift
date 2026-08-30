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
        guard segmentIndex < segments.count else { return }

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
            guard WildcardSegment.matches(pattern: segment, name: child.path.string) else { continue }

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
    let folder: NodeRecord

    public init(folder: NodeRecord) {
        self.folder = folder
    }

    public func allFiles(inDirectoryPath: String) throws -> [FileWildcardEntry] {
        guard let start = try folder.childNode(path: inDirectoryPath) else {
            throw NodeError.other(message: "No such directory: \(inDirectoryPath)")
        }

        return try start.allChildren.map { nodeRecord in
            switch nodeRecord.kind {

            case Folder.kind:
                guard let folder = try nodeRecord.makeNode() as? Folder else {
                    assert(false)
                    throw NodeError.other(message: "Unexpected object kind")
                }
                let isOutputFileSystem = try folder.thisNode
                    .buildFullPathName(baseNodeID: nil)
                    .firstComponent == Folder.outputFileSystemName
                return FileWildcardEntry(path: Path(nodeRecord.name!),
                                         kind: .folder,
                                         isMissing: isOutputFileSystem ? false : try !folder.isPinned,
                                         isUnreferenced: try folder.hasNoOutputWires() && nodeRecord.allChildren.isEmpty)

            default:
                let node = try nodeRecord.makeNode()
                guard let pinnable = node as? Pinnable else {
                    assert(false)
                    throw NodeError.other(message: "Unexpected object kind")
                }
                return FileWildcardEntry(path: Path(nodeRecord.name!),
                                         kind: .file,
                                         isMissing: try !pinnable.isPinned,
                                         isUnreferenced: try node.hasNoOutputWires())
            }
        }
    }
}
