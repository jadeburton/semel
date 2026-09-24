// InternalFileSystemLister.swift
// SemelCore
//
// The graph-backed side of the wildcard matcher. The matcher itself lives in SemelNodeKit
// so that a client can walk a real directory without linking the engine; this lister is
// the one input that needs `NodeRecord` and `Folder`, so it is the one part that stays.

import Foundation
import SemelDatabaseModels
import SemelNodeKit

public final class InternalFileSystemLister: FileWildcardMatcherInput {
    public let rootDirectoryPath = "/"
    let folder: NodeRecord

    public init(folder: NodeRecord) {
        self.folder = folder
    }

    /// Every child of a directory, each carrying what the port it is pinned by says, read
    /// by case: a listing built from these can tell a product whose build failed from a
    /// source on its way out of the input file system.
    public func allFiles(inDirectoryPath: String) throws -> [FileWildcardEntry] {
        guard let start = try folder.childNode(path: inDirectoryPath) else {
            throw NodeError.other(message: "No such directory: \(inDirectoryPath)")
        }

        return try start.allChildren.map { nodeRecord in
            switch nodeRecord.kind {

            case Folder.kind:
                guard let folder = try nodeRecord.makeNode() as? Folder else {
                    assert(false)
                    throw NodeError.other(message: "Unexpected object kind")
                }
                // A folder under `output:` is made by a build rather than pushed, so its pin
                // is not a state anyone can read anything from. `didCreate` gives such a
                // folder a value on that port, but the version migration restates a
                // preserved node's ports from its kind and port name alone, without asking
                // `canBePinned()` — so a graph carried across an upgrade can hold one
                // sitting on `initializing`, and this is what keeps that out of a listing.
                let isOutputFileSystem = try folder.thisNode
                    .buildFullPathName(baseNodeID: nil)
                    .firstComponent == Folder.outputFileSystemName
                return FileWildcardEntry(path: Path(nodeRecord.name!),
                                         kind: .folder,
                                         state: isOutputFileSystem ? .present : try folder.listedState,
                                         isUnreferenced: try folder.hasNoOutputWires() && nodeRecord.allChildren.isEmpty)

            default:
                let node = try nodeRecord.makeNode()
                guard let pinnable = node as? Pinnable else {
                    assert(false)
                    throw NodeError.other(message: "Unexpected object kind")
                }
                return FileWildcardEntry(path: Path(nodeRecord.name!),
                                         kind: .file,
                                         state: try pinnable.listedState,
                                         isUnreferenced: try node.hasNoOutputWires())
            }
        }
    }
}
