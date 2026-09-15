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
/// knows the product they belong to — can travel as one value.
struct FolderTreeBuilder: Node {

    public static let kind: UInt = 35

    /// The folder, one wire: `Folder(path: ...).manifest`.
    static let folderPort = "folder"
    static let subfoldersPort = "subfolders"
    static let filesPort = "files"
    static let outputPort = "files"
    /// A path put in front of every entry — `CAtomic` — so trees merged into one keep
    /// their folders apart.
    static let underProperty = "under"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(folderPort), .dynamic(subfoldersPort), .dynamic(filesPort)],
        outputPorts: [outputPort]
    )

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let roots      = FolderTreeWalk.manifests(in: input, port: Self.folderPort)
        let subfolders = FolderTreeWalk.manifests(in: input, port: Self.subfoldersPort)
        let manifests  = (roots + subfolders).map(\.manifest)
        let subfolderSpecs = FolderTreeWalk.subfolderSpecs(of: manifests)
        let fileSpecs      = FolderTreeWalk.fileSpecs(of: manifests)
        let specs = [Self.subfoldersPort: subfolderSpecs, Self.filesPort: fileSpecs]

        let arrivedSubfolders = Set(subfolders.map(\.key))
        let arrivedFiles      = Set((input.inputValues[Self.filesPort] ?? [:]).keys)
        guard let root = roots.first?.manifest,
              Set(subfolderSpecs.keys).isSubset(of: arrivedSubfolders),
              Set(fileSpecs.keys).isSubset(of: arrivedFiles) else {
            return .init(outputValues: [Self.outputPort: .noValue(reason: .pending)], inputWireSpecs: specs)
        }

        let rootPath = Path(root.baseFolderPath)
        let under = thisNode.properties[Self.underProperty].map { Path($0) } ?? .empty
        var entries: [TreeManifestEntry] = []
        for (fullPath, value) in (input.inputValues[Self.filesPort] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let relative = Path(fullPath).relative(to: rootPath) else {
                continue
            }
            entries.append(TreeManifestEntry(path: (under / relative).string, hash: try value.expectValue(),
                                             mode: FileMetadata.defaultMode))
        }
        return .init(outputValues: [Self.outputPort: .value(try TreeManifest(entries: entries).toJSON().intern())],
                     inputWireSpecs: specs)
    }
}
