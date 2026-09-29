//
//  FolderTreeWalk.swift
//  SemelNodeKit
//
//  How a node reaches every file under a folder it was given. A `FolderManifest` is a
//  non-recursive list of immediate children, so one pass reaches one level: the node
//  demands a manifest for each subfolder on a dynamic port of its own and a file wire for
//  each file, is rescheduled as they arrive, and repeats until the spec set stops
//  changing — the walk `SwiftCompiler` does for its sources and `ProjectFinder` for its
//  watched folders. A resource compiler handed an asset catalog does exactly the same, and
//  so does `ProjectBuilder` for a formula's `**` pattern, so the functions of it live here.

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
    /// subfolder's full path, for the subfolders `include` accepts. Unpinned entries are
    /// ghosts — deleted, or never pushed — and wiring one would resurrect a folder the
    /// user removed.
    ///
    /// A subfolder that is a symbolic link holds what the link names, and a walk reading
    /// files descends into it as into any folder. A walk building a tree passes
    /// `intoSymbolicLinks: false` and places the link instead (`symbolicLinkFolders(of:)`),
    /// so the tree holds the link and what it names once (B-77).
    public static func subfolderSpecs(of manifests: [FolderManifest],
                                      intoSymbolicLinks: Bool = true,
                                      include: (String) -> Bool = { _ in true }) -> [String: GraphSpecNode] {
        var result: [String: GraphSpecNode] = [:]
        for manifest in manifests {
            for entry in manifest.entries where entry.isFolder && entry.isPinned {
                guard intoSymbolicLinks || entry.symbolicLinkTarget == nil else {
                    continue
                }
                let fullPath = (Path(manifest.baseFolderPath) / entry.name).string
                guard include(fullPath) else {
                    continue
                }
                result[fullPath] = .folderManifest(at: fullPath)
            }
        }
        return result
    }

    /// Every pinned subfolder of `manifests` that is a symbolic link pushed as one, keyed
    /// by its full path, with what the link holds: what a walk building a tree places
    /// where it does not descend.
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

    /// Every subfolder below `root` the walk reaches through the manifests that have
    /// arrived, keyed by full path: the subfolders of `root`'s manifest, those of each of
    /// theirs that has arrived, and so on down, for the subfolders `include` accepts. A
    /// key whose manifest is not in `arrived` is where the walk stops this pass; the walk
    /// is finished when every key has arrived.
    ///
    /// From the root down, rather than over every manifest on the port, because a
    /// manifest still on a wire can belong to a folder that has since gone: only what the
    /// root reaches today is part of the tree.
    public static func subfolderSpecs(below root: String,
                                      arrived: [String: FolderManifest],
                                      intoSymbolicLinks: Bool = true,
                                      include: (String) -> Bool = { _ in true }) -> [String: GraphSpecNode] {
        var result: [String: GraphSpecNode] = [:]
        var level = arrived[root].map { [$0] } ?? []
        while !level.isEmpty {
            let found = subfolderSpecs(of: level, intoSymbolicLinks: intoSymbolicLinks, include: include)
                .filter { result[$0.key] == nil }
            result.merge(found) { existing, _ in existing }
            level = found.keys.sorted().compactMap { arrived[$0] }
        }
        return result
    }

    /// One `StaticFile(...).output` spec per pinned file of `manifests`, keyed by the
    /// file's full path, for the files `include` accepts.
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
