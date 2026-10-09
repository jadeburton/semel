//
//  FolderTreeBuilder.swift
//  SemelCore
//

import SemelNodeKit

/// A folder of the input file system as a tree value.
///
/// A `Folder` carries a manifest — names, one level — and a tree carries content, every
/// level. This reads the folder's subtree manifest for every name below it (B-135), and
/// puts every file on one port with its path relative to the folder, so a folder that
/// has to travel whole — a C target's headers and module map, for a formula that only
/// knows the product they belong to — can travel as one value. Each file keeps the mode
/// it was pushed with, which is demanded beside the file's bytes, and a file or folder
/// pushed as a symbolic link is the link it is: the read does not descend into a folder
/// link, and what a link names is in the tree where it is (B-77).
struct FolderTreeBuilder: Node {

    public static let kind: UInt = 35

    /// 2: each file's pushed mode, where every entry had the default. The walk demands
    /// the modes itself, so the passes before they arrive are keyed on the folder and the
    /// files alone — the key an entry of version 1 was written under.
    /// 3: a file pushed as a symbolic link is a link entry (B-77).
    /// 4: the folder's subtree manifest is asked for, where its subfolders were walked
    /// (B-135).
    public static let implementationVersion = 4

    /// The folder, one wire: `Folder(path: ...).manifest`.
    static let folderPort = "folder"
    /// The folder's subtree manifest, keyed by its path: every folder below it.
    static let folderTreePort = "folderTree"
    static let filesPort = "files"
    /// Each file's `fileMetadata`, under the key its bytes arrive under on `files`.
    static let fileMetadataPort = FileMetadata.portName
    static let outputPort = "files"
    /// A path put in front of every entry — `CAtomic` — so trees merged into one keep
    /// their folders apart.
    static let underProperty = "under"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(folderPort, .many), .dynamic(folderTreePort), .dynamic(filesPort), .dynamic(fileMetadataPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let roots = FolderTreeWalk.manifests(in: input, port: Self.folderPort)
        let trees = FolderTreeWalk.trees(in: input, port: Self.folderTreePort)
        var treeSpecs: [String: GraphSpecNode] = [:]
        var reached: [String: FolderManifest] = [:]
        for root in roots.map(\.manifest) {
            treeSpecs[root.baseFolderPath] = .folderTree(at: root.baseFolderPath)
            guard let tree = trees[root.baseFolderPath] else {
                reached[root.baseFolderPath] = root
                continue
            }
            reached.merge(try tree.folderManifests(at: root.baseFolderPath, intoSymbolicLinks: false)) { existing, _ in existing }
        }
        let manifests     = reached.keys.sorted().compactMap { reached[$0] }
        let fileSpecs     = FolderTreeWalk.fileSpecs(of: manifests)
        let metadataSpecs = fileSpecs.mapValues { $0.port(FileMetadata.portName) }
        let specs = [Self.folderTreePort:   treeSpecs,
                     Self.filesPort:        fileSpecs,
                     Self.fileMetadataPort: metadataSpecs]

        let metadata     = input.inputValues[Self.fileMetadataPort] ?? [:]
        let arrivedFiles = Set((input.inputValues[Self.filesPort] ?? [:]).keys)
        guard let root = roots.first?.manifest,
              Set(treeSpecs.keys).isSubset(of: Set(trees.keys)),
              Set(fileSpecs.keys).isSubset(of: arrivedFiles),
              Set(fileSpecs.keys).isSubset(of: Set(metadata.keys)) else {
            return .init(outputValues: [Self.outputPort: .noValue(reason: .pending)], inputWireSpecs: specs)
        }

        let rootPath = Path(root.baseFolderPath)
        let under = thisNode.properties[Self.underProperty].map { Path($0) } ?? .empty
        var files: [TreeManifest.PlacedFile] = []
        for (fullPath, value) in (input.inputValues[Self.filesPort] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let relative = Path(fullPath).relative(to: rootPath) else {
                continue
            }
            files.append(.init(path: (under / relative).string, hash: try value.expectValue(),
                               metadata: FileMetadata.metadata(of: metadata[fullPath])))
        }
        var folderLinks: [String: String] = [:]
        for (fullPath, target) in FolderTreeWalk.symbolicLinkFolders(of: manifests).sorted(by: { $0.key < $1.key }) {
            guard let relative = Path(fullPath).relative(to: rootPath) else {
                continue
            }
            folderLinks[(under / relative).string] = target
        }
        let tree = TreeManifest(placing: files, folderLinks: folderLinks)
        return .init(outputValues: [Self.outputPort: .value(try tree.toJSON().intern())],
                     inputWireSpecs: specs)
    }
}
