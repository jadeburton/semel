//
//  FolderTreeWalk.swift
//  SemelNodeKit
//
//  How a node reaches every file under a folder it was given. A `FolderManifest` is a
//  non-recursive list of immediate children, so one pass reaches one level: the node
//  demands a manifest for each subfolder on a dynamic port of its own and a file wire for
//  each file, is rescheduled as they arrive, and repeats until the spec set stops
//  changing — the walk `SwiftCompiler` does for its sources and `ProjectFinder` for its
//  watched folders. A resource compiler handed an asset catalog does exactly the same,
//  so the three functions of it live here.

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

    /// One `Folder(...).manifest` spec per pinned subfolder of `manifests`, keyed by the
    /// subfolder's full path. Unpinned entries are ghosts — deleted, or never pushed — and
    /// wiring one would resurrect a folder the user removed.
    public static func subfolderSpecs(of manifests: [FolderManifest]) -> [String: String] {
        var result: [String: String] = [:]
        for manifest in manifests {
            for entry in manifest.entries where entry.isFolder && entry.isPinned {
                let fullPath = (Path(manifest.baseFolderPath) / entry.name).string
                result[fullPath] = "Folder(path: '\(fullPath)').manifest"
            }
        }
        return result
    }

    /// One `StaticFile(...).output` spec per pinned file of `manifests`, keyed by the
    /// file's full path, for the files `include` accepts.
    public static func fileSpecs(of manifests: [FolderManifest],
                                 include: (String) -> Bool = { _ in true }) -> [String: String] {
        var result: [String: String] = [:]
        for manifest in manifests {
            for entry in manifest.entries where !entry.isFolder && entry.isPinned {
                let fullPath = (Path(manifest.baseFolderPath) / entry.name).string
                guard include(fullPath) else {
                    continue
                }
                result[fullPath] = "StaticFile(path: '\(fullPath)').output"
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
