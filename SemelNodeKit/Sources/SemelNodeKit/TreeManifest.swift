//
//  TreeManifest.swift
//  SemelNodeKit
//
//  A port carries one value. A tool that writes a directory of results — an asset
//  catalog compiler's `Assets.car` and one PNG per icon size, a string catalog compiler's
//  one `.lproj` per language — decides its own file set, which no formula can name in
//  advance. A tree is how one port carries N files: a manifest of relative paths, each
//  with the content hash and the mode, interned like any value. Nothing about wires,
//  caching or the database changes; what changes is that a node can say "here are N
//  files" and a product can publish every one of them.

/// One file of a tree.
public struct TreeManifestEntry: Codable, Equatable {
    /// Relative to the tree's root, `/`-separated: `en.lproj/Localizable.strings`.
    public let path: String
    /// SHA-256 hex digest of the content in `DataObjectStore`.
    public let hash: String
    /// POSIX permission bits, so an executable inside a tree stays one.
    public let mode: UInt16

    public init(path: String, hash: String, mode: UInt16) {
        self.path = path
        self.hash = hash
        self.mode = mode
    }
}

public struct TreeManifest: PolySerializable, Equatable {
    public static let kind: UInt = 27

    /// Sorted by path, whatever order they were collected in: a manifest is a value, and
    /// two trees with the same files must intern to the same hash.
    public let entries: [TreeManifestEntry]

    public init(entries: [TreeManifestEntry]) {
        self.entries = entries.sorted { $0.path < $1.path }
    }

    public func entry(at path: String) -> TreeManifestEntry? {
        entries.first { $0.path == path }
    }

    /// Every file of every tree wired to `port`, as sandbox inputs: each entry placed under
    /// the wire's key, so two trees holding one path cannot collide, ordered by key then
    /// path so a command line built from them is the same on every run. A tree still
    /// pending or in error throws, as any input value does, and the node waits or fails.
    public static func inputFiles(in input: ProcessInput, port: String) throws -> [FileNameAndContent] {
        var files: [FileNameAndContent] = []
        for (key, value) in (input.inputValues[port] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try value.expectValue().resolveAsString())
            for entry in manifest.entries {
                files.append(FileNameAndContent(filePath: (Path(key) / Path(entry.path)).string, hash: entry.hash))
            }
        }
        return files
    }

    /// Every file of every tree wired to `port`, merged into one folder `under`: an entry
    /// two trees both hold is one file when its content is the same — two products that
    /// share a target share its object, and linking it twice is a duplicate symbol — and
    /// an error naming the path when it is not. Ordered by path.
    public static func mergedInputFiles(in input: ProcessInput, port: String, under folder: String) throws -> [FileNameAndContent] {
        var hashes: [String: String] = [:]
        var from: [String: String] = [:]
        for (key, value) in (input.inputValues[port] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try value.expectValue().resolveAsString())
            for entry in manifest.entries {
                if let earlier = hashes[entry.path], earlier != entry.hash {
                    throw NodeError.other(message: "'\(entry.path)' differs between \(from[entry.path] ?? "?") and \(key)")
                }
                hashes[entry.path] = entry.hash
                from[entry.path] = from[entry.path] ?? key
            }
        }
        return hashes.sorted { $0.key < $1.key }
            .map { FileNameAndContent(filePath: (Path(folder) / Path($0.key)).string, hash: $0.value) }
    }
}
