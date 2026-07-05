// FileWildcardMatcher.swift
// build_system

import Foundation

enum FileWildcardEntryKind {
    case file
    case folder
}

struct FileWildcardEntry {
    let path: String
    let kind: FileWildcardEntryKind
    let isMissing: Bool       // file is missing from the internal file system
    let isUnreferenced: Bool
}

protocol FileWildcardMatcherInput {
    var rootDirectoryPath: String { get }
    func allFiles(inDirectoryPath: String) throws -> [FileWildcardEntry]
}

// MARK: - FileWildcardMatcher

final class FileWildcardMatcher {
    private let input: FileWildcardMatcherInput

    init(input: FileWildcardMatcherInput) {
        self.input = input
    }

    /// Find all files and folders matching a glob pattern.
    ///
    /// Supports:
    /// - `?`  — matches any single character
    /// - `*`  — matches zero or more characters within a single path segment
    /// - `**` — matches zero or more directory levels (recursive)
    func findAllMatching(pathOrWildcard: String) throws -> [FileWildcardEntry] {
        let normalised = pathOrWildcard.hasPrefix("/")
            ? pathOrWildcard
            : "/" + pathOrWildcard

        let segments = normalised
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var results: [FileWildcardEntry] = []
        try matchSegments(
            segments: segments,
            segmentIndex: 0,
            currentDirectory: input.rootDirectoryPath,
            currentLogicalPath: "",
            results: &results
        )
        return results
    }

    // MARK: - Private recursive matcher

    private func joinLogicalPath(_ base: String, _ child: String) -> String {
        base.isEmpty ? child : base + "/" + child
    }

    private func matchSegments(
        segments: [String],
        segmentIndex: Int,
        currentDirectory: String,
        currentLogicalPath: String,
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
                let childLogicalPath  = joinLogicalPath(currentLogicalPath, child.path)
                let childPhysicalPath = (currentDirectory as NSString).appendingPathComponent(child.path)
                try matchSegments(segments: segments, segmentIndex: segmentIndex,
                                  currentDirectory: childPhysicalPath,
                                  currentLogicalPath: childLogicalPath, results: &results)
            }
            return
        }

        // ── Normal or single-star segment ─────────────────────────
        let children = try input.allFiles(inDirectoryPath: currentDirectory)
        for child in children {
            guard segmentMatches(pattern: segment, name: child.path) else { continue }

            let childLogicalPath = joinLogicalPath(currentLogicalPath, child.path)

            if isLastSegment {
                results.append(FileWildcardEntry(path: childLogicalPath, kind: child.kind,
                                                 isMissing: child.isMissing,
                                                 isUnreferenced: child.isUnreferenced))
            } else if child.kind == .folder {
                let childPhysicalPath = (currentDirectory as NSString).appendingPathComponent(child.path)
                try matchSegments(segments: segments, segmentIndex: segmentIndex + 1,
                                  currentDirectory: childPhysicalPath,
                                  currentLogicalPath: childLogicalPath, results: &results)
            }
        }
    }

    // MARK: - Segment-level glob matching

    private func segmentMatches(pattern: String, name: String) -> Bool {
        globMatch(pattern: Array(pattern.unicodeScalars), pi: 0,
                  text: Array(name.unicodeScalars), ti: 0)
    }

    private func globMatch(pattern: [Unicode.Scalar], pi: Int,
                           text: [Unicode.Scalar], ti: Int) -> Bool {
        var pi = pi; var ti = ti
        var starPI = -1; var starTI = -1

        while ti < text.count {
            if pi < pattern.count && (pattern[pi] == "?" || pattern[pi] == text[ti]) {
                pi += 1; ti += 1
            } else if pi < pattern.count && pattern[pi] == "*" {
                starPI = pi + 1; starTI = ti; pi += 1
            } else if starPI != -1 {
                starTI += 1; ti = starTI; pi = starPI
            } else {
                return false
            }
        }
        while pi < pattern.count && pattern[pi] == "*" { pi += 1 }
        return pi == pattern.count
    }
}

// MARK: - ExternalFileSystemLister

final class ExternalFileSystemLister: FileWildcardMatcherInput {
    let rootDirectoryPath: String

    init(rootDirectoryPath: String) {
        self.rootDirectoryPath = rootDirectoryPath
    }

    func allFiles(inDirectoryPath path: String) -> [FileWildcardEntry] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return children.compactMap { name -> FileWildcardEntry? in
            guard !name.hasPrefix(".") else { return nil }
            let fullPath = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { return nil }
            return FileWildcardEntry(path: name,
                                     kind: isDir.boolValue ? .folder : .file,
                                     isMissing: false, isUnreferenced: false)
        }.sorted { $0.path < $1.path }
    }
}

// MARK: - InternalFileSystemLister

final class InternalFileSystemLister: FileWildcardMatcherInput {
    let rootDirectoryPath = "/"
    let folder: Node

    init(folder: Node) {
        self.folder = folder
    }

    func allFiles(inDirectoryPath: String) throws -> [FileWildcardEntry] {
        let start = try folder.childNode(path: inDirectoryPath)!

        return try! start.allChildren.map { node in
            switch node.kind {

            case Folder.kind:
                guard let folder = try node.nodeFunction() as? Folder else {
                    assert(false)
                    throw NodeError.other(message: "Unexpected object kind")
                }
                let isOutputFileSystem = try folder.thisNode
                    .buildFullPathName(baseNodeID: nil)
                    .hasPrefix("outputFileSystem")
                return FileWildcardEntry(path: node.name!,
                                         kind: .folder,
                                         isMissing: isOutputFileSystem ? false : try !folder.isPinned,
                                         isUnreferenced: try folder.hasNoOutputWires() && node.allChildren.isEmpty)

            default:
                let nodeFunction = try node.nodeFunction()
                guard let pinnable = nodeFunction as? Pinnable else {
                    assert(false)
                    throw NodeError.other(message: "Unexpected object kind")
                }
                return FileWildcardEntry(path: node.name!,
                                         kind: .file,
                                         isMissing: try !pinnable.isPinned,
                                         isUnreferenced: try nodeFunction.hasNoOutputWires())
            }
        }
    }
}
