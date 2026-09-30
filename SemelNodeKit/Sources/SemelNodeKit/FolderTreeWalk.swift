//
//  FolderTreeWalk.swift
//  SemelNodeKit
//
//  How a node reaches every file under a folder it was given. A `FolderManifest` lists a
//  folder's own children, and a folder's subtree manifest every name below it (B-135), so
//  the node asks for the tree of each folder it was given (`GraphSpecNode.folderTree(at:)`),
//  reads it down as far as it means to go (`FolderSubtreeManifest.folderManifests(at:)`),
//  and demands a file wire for each file it found — two passes however deep the folder,
//  where a walk over manifests took one per level. `SwiftCompiler` does this for its
//  sources, `ClangPreprocessor` for its header folders, `AssetCatalogCompiler` for a
//  catalog, `FolderTreeBuilder` and `XCFrameworkSliceSelector` for a folder they make a
//  tree of; the functions they share live here. A node that needs the names and not the
//  files — a converter, `ProjectBuilder`'s `**`, `ProjectFinder` — stops at the tree.

public enum FolderTreeWalk {

    /// Every `FolderManifest` wired to `port`, ordered by wire key. Ordered, because the
    /// files these yield end up on a command line, and Swift's Dictionary order is seeded
    /// per process. A wire that carries no manifest yet contributes nothing.
    public static func manifests(in input: ProcessInput, port: String) -> [(key: String, manifest: FolderManifest)] {
        var result: [(key: String, manifest: FolderManifest)] = []
        for (key, value) in (input.inputValues[port] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let json = try? value.expectValue().resolveAsString(),
                  let manifest: FolderManifest = try? TypeRegistry.decodeAndCast(encodedJSON: json) else {
                continue
            }
            result.append((key, manifest))
        }
        return result
    }

    /// Every `FolderSubtreeManifest` wired to `port` (`GraphSpecNode.folderTree(at:)`), keyed
    /// by wire key — the folder's path. A wire that carries no tree yet contributes nothing,
    /// which is how a reader tells a tree still on its way from one that has arrived.
    public static func trees(in input: ProcessInput, port: String) -> [String: FolderSubtreeManifest] {
        var result: [String: FolderSubtreeManifest] = [:]
        for (key, value) in (input.inputValues[port] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let json = try? value.expectValue().resolveAsString(),
                  let tree: FolderSubtreeManifest = try? TypeRegistry.decodeAndCast(encodedJSON: json) else {
                continue
            }
            result[key] = tree
        }
        return result
    }

    /// Every pinned subfolder of `manifests` that is a symbolic link pushed as one, keyed
    /// by its full path, with what the link holds: what a node building a tree places
    /// where it does not descend. Such a folder holds what the link names, so a node
    /// reading files descends into it as into any folder; one building a tree reads the
    /// tree with `intoSymbolicLinks: false` and places the link instead, so the tree holds
    /// the link and what it names once (B-77).
    public static func symbolicLinkFolders(of manifests: [FolderManifest]) -> [String: String] {
        var result: [String: String] = [:]
        for manifest in manifests {
            for entry in manifest.entries where entry.isFolder && entry.isPinned {
                guard let target = entry.symbolicLinkTarget else {
                    continue
                }
                result[(Path(manifest.baseFolderPath) / entry.name).string] = target
            }
        }
        return result
    }

    /// One `StaticFile(...).output` spec per pinned file of `manifests`, keyed by the
    /// file's full path, for the files `include` accepts. Unpinned entries are ghosts —
    /// deleted, or never pushed — and wiring one would resurrect a file the user removed.
    public static func fileSpecs(of manifests: [FolderManifest],
                                 include: (String) -> Bool = { _ in true }) -> [String: GraphSpecNode] {
        var result: [String: GraphSpecNode] = [:]
        for manifest in manifests {
            for entry in manifest.entries where !entry.isFolder && entry.isPinned {
                let fullPath = (Path(manifest.baseFolderPath) / entry.name).string
                guard include(fullPath) else {
                    continue
                }
                result[fullPath] = .staticFile(at: fullPath)
            }
        }
        return result
    }

    /// The files that have arrived on `port`, sorted by wire key — the full path each was
    /// demanded by — with `relativeTo` mapping that path to where the file goes in the
    /// sandbox. A file still pending is not there yet, which is the node's cue that the
    /// walk has not finished.
    public static func files(in input: ProcessInput, port: String,
                             relativeTo sandboxPath: (String) -> String) throws -> [FileNameAndContent] {
        try (input.inputValues[port] ?? [:])
            .sorted { $0.key < $1.key }
            .map { key, value in FileNameAndContent(filePath: sandboxPath(key), hash: try value.expectValue()) }
    }
}
