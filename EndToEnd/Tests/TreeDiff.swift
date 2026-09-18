//
//  TreeDiff.swift
//  SemelEndToEndTests
//
//  Two export trees compared: the same set of relative paths, the same modes, the same
//  bytes. Each difference names its path and how it differs, so a timestamp or an
//  embedded path is recognisable from the message without opening the files.
//

import Foundation

enum TreeDiff {

    struct Difference: CustomStringConvertible {
        enum Kind {
            case onlyInFirst
            case onlyInSecond
            case mode(first: Int, second: Int)
            case size(first: Int, second: Int)
            case content(firstDifferingOffset: Int)
        }
        let path: String
        let kind: Kind

        var description: String {
            switch kind {
            case .onlyInFirst:                    return "\(path): only in the first tree"
            case .onlyInSecond:                   return "\(path): only in the second tree"
            case .mode(let a, let b):             return "\(path): mode \(String(a, radix: 8)) vs \(String(b, radix: 8))"
            case .size(let a, let b):             return "\(path): size \(a) vs \(b)"
            case .content(let offset):            return "\(path): content differs at offset \(offset)"
            }
        }
    }

    /// Sorted by path. Files only; a directory is present through what is in it.
    static func compare(_ first: URL, _ second: URL) throws -> [Difference] {
        let firstFiles = try files(under: first)
        let secondFiles = try files(under: second)
        var differences: [Difference] = []
        for path in Set(firstFiles.keys).union(secondFiles.keys).sorted() {
            guard let a = firstFiles[path] else {
                differences.append(.init(path: path, kind: .onlyInSecond))
                continue
            }
            guard let b = secondFiles[path] else {
                differences.append(.init(path: path, kind: .onlyInFirst))
                continue
            }
            if a.mode != b.mode {
                differences.append(.init(path: path, kind: .mode(first: a.mode, second: b.mode)))
            } else if a.size != b.size {
                differences.append(.init(path: path, kind: .size(first: a.size, second: b.size)))
            } else if let offset = try firstDifferingOffset(a.url, b.url) {
                differences.append(.init(path: path, kind: .content(firstDifferingOffset: offset)))
            }
        }
        return differences
    }

    private struct Entry {
        let url: URL
        let mode: Int
        let size: Int
    }

    private static func files(under root: URL) throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            return result
        }
        let rootPath = canonicalPath(root)
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: keys).isRegularFile == true else {
                continue
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let relative = String(url.path.dropFirst(rootPath.count + 1))
            result[relative] = Entry(url: url,
                                     mode: (attributes[.posixPermissions] as? Int ?? 0) & 0o777,
                                     size: attributes[.size] as? Int ?? 0)
        }
        return result
    }

    /// `FileManager`'s enumerator resolves the symlinks in its root (`/tmp` and
    /// `/var/folders` both sit behind one on macOS), so the prefix stripped from each
    /// enumerated path has to be resolved the same way, or a root reached through such a
    /// symlink yields relative paths with a leftover fragment of the real path.
    private static func canonicalPath(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else {
            return url.path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func firstDifferingOffset(_ a: URL, _ b: URL) throws -> Int? {
        let dataA = try Data(contentsOf: a)
        let dataB = try Data(contentsOf: b)
        guard dataA != dataB else {
            return nil
        }
        return zip(dataA, dataB).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(dataA.count, dataB.count)
    }
}
