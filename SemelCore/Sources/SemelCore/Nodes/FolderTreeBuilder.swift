//
//  FolderTreeBuilder.swift
//  SemelCore
//

import SemelNodeKit

/// A folder of the input file system as a tree value.
///
/// A `Folder` carries a manifest — names, one level — and a tree carries content, every
/// level. This walks the folder the way every folder walk goes, one level per pass, and
/// puts every file on one port with its path relative to the folder, so a folder that
/// has to travel whole — a C target's headers and module map, for a formula that only
/// knows the product they belong to — can travel as one value. Each file keeps the mode
/// it was pushed with, which is demanded beside the file's bytes, and a file or folder
/// pushed as a symbolic link is the link it is: the walk does not descend into a folder
/// link, and what a link names is in the tree where it is (B-77).
struct FolderTreeBuilder: Node {

    public static let kind: UInt = 35

    /// 2: each file's pushed mode, where every entry had the default. The walk demands
    /// the modes itself, so the passes before they arrive are keyed on the folder and the
    /// files alone — the key an entry of version 1 was written under.
    /// 3: a file pushed as a symbolic link is a link entry (B-77).
    public static let implementationVersion = 3

    /// The folder, one wire: `Folder(path: ...).manifest`.
    static let folderPort = "folder"
    static let subfoldersPort = "subfolders"
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
        inputPorts: [.required(folderPort), .dynamic(subfoldersPort), .dynamic(filesPort), .dynamic(fileMetadataPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let roots      = FolderTreeWalk.manifests(in: input, port: Self.folderPort)
        let subfolders = FolderTreeWalk.manifests(in: input, port: Self.subfoldersPort)
        let manifests  = (roots + subfolders).map(\.manifest)
        let subfolderSpecs = FolderTreeWalk.subfolderSpecs(of: manifests, intoSymbolicLinks: false)
        let fileSpecs      = FolderTreeWalk.fileSpecs(of: manifests)
        let metadataSpecs  = fileSpecs.mapValues { $0.port(FileMetadata.portName) }
        let specs = [Self.subfoldersPort:   subfolderSpecs,
                     Self.filesPort:        fileSpecs,
                     Self.fileMetadataPort: metadataSpecs]

        let metadata          = input.inputValues[Self.fileMetadataPort] ?? [:]
        let arrivedSubfolders = Set(subfolders.map(\.key))
        let arrivedFiles      = Set((input.inputValues[Self.filesPort] ?? [:]).keys)
        guard let root = roots.first?.manifest,
              Set(subfolderSpecs.keys).isSubset(of: arrivedSubfolders),
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
