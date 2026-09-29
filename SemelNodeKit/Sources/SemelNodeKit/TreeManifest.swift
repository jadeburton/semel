//
//  TreeManifest.swift
//  SemelNodeKit
//
//  A port carries one value. A tool that writes a directory of results — an asset
//  catalog compiler's `Assets.car` and one PNG per icon size, a string catalog compiler's
//  one `.lproj` per language — decides its own file set, which no formula can name in
//  advance. A tree is how one port carries N files: a manifest of relative paths, each
//  with the content hash and the mode, or the target of a symbolic link, interned like any
//  value. Nothing about wires, caching or the database changes; what changes is that a
//  node can say "here are N files" and a product can publish every one of them.

/// One entry of a tree: a file, or a symbolic link.
public struct TreeManifestEntry: Equatable {

    /// What is at an entry's path.
    public enum Content: Equatable {
        /// A file: its SHA-256 hex digest in `DataObjectStore`, and its POSIX permission
        /// bits, so an executable inside a tree stays one.
        case file(hash: String, mode: UInt16)
        /// A symbolic link, as it holds its target: relative to the entry's folder —
        /// `Versions/Current/Tiny`. A tree holds a link only where the target names a file
        /// or a folder of the same tree (`TreeManifest(placing:)`), which is what lets a
        /// versioned framework travel as the vendor built it (B-77).
        case symbolicLink(target: String)
    }

    /// Relative to the tree's root, `/`-separated: `en.lproj/Localizable.strings`.
    public let path: String
    public let content: Content

    public init(path: String, content: Content) {
        self.path = path
        self.content = content
    }

    public init(path: String, hash: String, mode: UInt16) {
        self.init(path: path, content: .file(hash: hash, mode: mode))
    }

    public init(path: String, symbolicLinkTarget: String) {
        self.init(path: path, content: .symbolicLink(target: symbolicLinkTarget))
    }

    /// The file's content hash; nil for a link, which has no content of its own.
    public var hash: String? {
        guard case .file(let hash, _) = content else {
            return nil
        }
        return hash
    }

    /// The file's mode; nil for a link, whose mode no tool reads.
    public var mode: UInt16? {
        guard case .file(_, let mode) = content else {
            return nil
        }
        return mode
    }

    /// The link's target; nil for a file.
    public var symbolicLinkTarget: String? {
        guard case .symbolicLink(let target) = content else {
            return nil
        }
        return target
    }

    /// The entry with `folder` in front of its path. A link keeps its target: it is
    /// relative to the link's own folder, which moves with it.
    public func placed(under folder: Path) -> TreeManifestEntry {
        TreeManifestEntry(path: (folder / Path(path)).string, content: content)
    }
}

// MARK: - Encoding

/// Spelled out rather than synthesized, as `FolderContentRoot`'s document is: a manifest is
/// a value, and two trees with the same entries must intern to the same hash in every
/// release. A file is `{"hash","mode","path"}`, the shape every tree had before links; a
/// link is `{"path","symbolicLink"}`. `TypeRegistry` sorts the keys.
extension TreeManifestEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case path
        case hash
        case mode
        case symbolicLink
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        if let target = try container.decodeIfPresent(String.self, forKey: .symbolicLink) {
            content = .symbolicLink(target: target)
            return
        }
        content = .file(hash: try container.decode(String.self, forKey: .hash),
                        mode: try container.decode(UInt16.self, forKey: .mode))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        switch content {
        case .file(let hash, let mode):
            try container.encode(hash, forKey: .hash)
            try container.encode(mode, forKey: .mode)
        case .symbolicLink(let target):
            try container.encode(target, forKey: .symbolicLink)
        }
    }
}

// MARK: - The manifest

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
    /// path so a command line built from them is the same on every run. A link is laid as
    /// a link. A tree still pending or in error throws, as any input value does, and the
    /// node waits or fails.
    public static func inputFiles(in input: ProcessInput, port: String) throws -> [FileNameAndContent] {
        var files: [FileNameAndContent] = []
        for (key, value) in (input.inputValues[port] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try value.expectValue().resolveAsString())
            for entry in manifest.entries {
                files.append(entry.placed(under: Path(key)).asInputFile)
            }
        }
        return files
    }

    /// Every file of every tree wired to `port`, merged into one folder `under`: an entry
    /// two trees both hold is one file when its content is the same — two products that
    /// share a target share its object, and linking it twice is a duplicate symbol — and
    /// an error naming the path when it is not. Ordered by path.
    public static func mergedInputFiles(in input: ProcessInput, port: String, under folder: String) throws -> [FileNameAndContent] {
        var merged = TreeMerge()
        for (key, value) in (input.inputValues[port] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try value.expectValue().resolveAsString())
            if let collision = merged.add(manifest.entries, from: key) {
                throw NodeError.other(message: collision.description)
            }
        }
        if let collision = merged.collisionBelowALink {
            throw NodeError.other(message: collision.description)
        }
        return merged.manifest.entries.map { $0.placed(under: Path(folder)).asInputFile }
    }
}

extension TreeManifestEntry {
    /// The entry as a tool is handed it: a file by its hash, a link as a link.
    public var asInputFile: FileNameAndContent {
        switch content {
        case .file(let hash, _):
            return FileNameAndContent(filePath: path, hash: hash)
        case .symbolicLink(let target):
            return FileNameAndContent(symbolicLinkAt: path, target: target)
        }
    }
}

// MARK: - Merging

/// Several trees' entries as one, with the one rule every merge keeps: a path two trees
/// hold is one entry when both hold the same thing there, and a collision otherwise — and a
/// link one tree holds where another holds something below it is a collision too, since
/// the one cannot be laid without replacing the other.
public struct TreeMerge {
    /// Why two trees cannot be one.
    public struct Collision: Error, CustomStringConvertible {
        public let path: String
        public let first: String
        public let second: String

        public var description: String {
            "two trees hold '\(path)': \(first) and \(second)"
        }
    }

    private var entries: [String: TreeManifestEntry] = [:]
    private var from: [String: String] = [:]

    public init() {}

    /// Adds `entries`, which came from `source` — a wire's key, for the collision to name —
    /// or answers the first collision they make with what was already added.
    public mutating func add(_ newEntries: [TreeManifestEntry], from source: String) -> Collision? {
        for entry in newEntries {
            if let held = entries[entry.path] {
                guard held.content == entry.content else {
                    return Collision(path: entry.path, first: from[entry.path] ?? "?", second: source)
                }
                continue
            }
            entries[entry.path] = entry
            from[entry.path] = source
        }
        return nil
    }

    /// What was merged.
    public var manifest: TreeManifest {
        TreeManifest(entries: entries.keys.sorted().compactMap { entries[$0] })
    }

    /// A link with entries below its path: the one collision paths alone do not show.
    public var collisionBelowALink: Collision? {
        let sorted = entries.keys.sorted()
        for (index, path) in sorted.enumerated() where entries[path]?.symbolicLinkTarget != nil {
            let below = path + "/"
            if index + 1 < sorted.count, sorted[index + 1].hasPrefix(below) {
                return Collision(path: path, first: from[path] ?? "?", second: from[sorted[index + 1]] ?? "?")
            }
        }
        return nil
    }
}

// MARK: - Links in a tree

extension TreeManifest {

    /// What a path names in the tree, links followed.
    public enum Resolution: Equatable {
        /// A file entry: the one reached, links followed.
        case file(TreeManifestEntry)
        /// A folder: a path some entry lies below, or the tree's root.
        case folder
    }

    /// What `path` names in this tree, each link on the way followed from the folder that
    /// holds it and each `..` taken from where the walk has got to, as a file system reads
    /// one; nil when it names nothing here — a missing entry, a climb above the root, an
    /// absolute target, a file with a path below it, or a chain of links too long to be
    /// anything but a loop.
    public func resolve(_ path: String) -> Resolution? {
        TreeIndex(entries: entries).resolve(path)
    }

    /// A tree of what a builder read: each file as it arrived, each file pushed as a link a
    /// link where its target resolves among what is placed here, or otherwise the bytes it
    /// carries with its mode — the copy a push made of every link before links were
    /// entries, which is what a tree holds when the file a link names is not in it. Each
    /// folder that is a link (`folderLinks`, by path, what the link holds) is a link where
    /// its target resolves, and is left out where it does not: a walk building a tree does
    /// not descend into one, and a folder link inside its own folder names nothing here
    /// only when what it names holds nothing a push would push.
    ///
    /// Placed again until nothing changes, because a link placed as a copy can be what
    /// another link named as a folder. Each round places at least one link otherwise, so it
    /// ends. What comes out holds only links that resolve inside it, which placing it under
    /// a folder and merging it with others keep true.
    public init(placing files: [PlacedFile], folderLinks: [String: String] = [:]) {
        var fileLinks   = Set(files.filter { $0.metadata.symbolicLinkTarget != nil }.map(\.path))
        var folderLinks = folderLinks
        while true {
            let entries = files.map { $0.entry(asLink: fileLinks.contains($0.path)) }
                + folderLinks.sorted { $0.key < $1.key }.map { TreeManifestEntry(path: $0.key, symbolicLinkTarget: $0.value) }
            let index = TreeIndex(entries: entries)
            let unresolvedFiles   = fileLinks.sorted().filter { index.resolve($0) == nil }
            let unresolvedFolders = folderLinks.keys.sorted().filter { index.resolve($0) == nil }
            guard !unresolvedFiles.isEmpty || !unresolvedFolders.isEmpty else {
                self.init(entries: entries)
                return
            }
            fileLinks.subtract(unresolvedFiles)
            unresolvedFolders.forEach { folderLinks[$0] = nil }
        }
    }

    /// One file a builder read from its ports on the way into a tree: the path it takes in
    /// the tree, the hash on its `output` and what its `fileMetadata` said.
    public struct PlacedFile {
        public let path: String
        public let hash: String
        public let metadata: FileMetadata

        public init(path: String, hash: String, metadata: FileMetadata) {
            self.path = path
            self.hash = hash
            self.metadata = metadata
        }

        func entry(asLink: Bool) -> TreeManifestEntry {
            if asLink, let target = metadata.symbolicLinkTarget {
                return TreeManifestEntry(path: path, symbolicLinkTarget: target)
            }
            return TreeManifestEntry(path: path, hash: hash, mode: metadata.mode ?? FileMetadata.defaultMode)
        }
    }
}

/// The entries by path and every folder they lie in, for following links.
private struct TreeIndex {
    let entries: [String: TreeManifestEntry]
    let folders: Set<String>

    /// Longer than any chain a real tree holds — the kernel's own limit is 32 — and short
    /// enough that a loop is found at once.
    static let linkHopLimit = 40

    init(entries list: [TreeManifestEntry]) {
        var entries: [String: TreeManifestEntry] = [:]
        var folders = Set<String>()
        for entry in list {
            entries[entry.path] = entry
            var components = entry.path.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                folders.insert(components.joined(separator: "/"))
            }
        }
        self.entries = entries
        self.folders = folders
    }

    func resolve(_ path: String) -> TreeManifest.Resolution? {
        var pending = Array(path.split(separator: "/").map(String.init).reversed())
        var reached: [String] = []
        var hops = 0
        while let component = pending.popLast() {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                guard !reached.isEmpty else {
                    return nil
                }
                reached.removeLast()
                continue
            }
            let candidate = (reached + [component]).joined(separator: "/")
            if let entry = entries[candidate] {
                switch entry.content {
                case .file:
                    return pending.isEmpty ? .file(entry) : nil
                case .symbolicLink(let target):
                    hops += 1
                    guard hops <= Self.linkHopLimit, !target.hasPrefix("/") else {
                        return nil
                    }
                    // The target is read from the link's folder, where the walk stands.
                    pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
                }
                continue
            }
            guard folders.contains(candidate) else {
                return nil
            }
            reached.append(component)
        }
        return .folder
    }
}
