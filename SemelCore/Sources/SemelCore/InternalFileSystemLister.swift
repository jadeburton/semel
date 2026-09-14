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
                let isOutputFileSystem = try folder.thisNode
                    .buildFullPathName(baseNodeID: nil)
                    .firstComponent == Folder.outputFileSystemName
                return FileWildcardEntry(path: Path(nodeRecord.name!),
                                         kind: .folder,
                                         isMissing: isOutputFileSystem ? false : try !folder.isPinned,
                                         isUnreferenced: try folder.hasNoOutputWires() && nodeRecord.allChildren.isEmpty)

            default:
                let node = try nodeRecord.makeNode()
                guard let pinnable = node as? Pinnable else {
                    assert(false)
                    throw NodeError.other(message: "Unexpected object kind")
                }
                return FileWildcardEntry(path: Path(nodeRecord.name!),
                                         kind: .file,
                                         isMissing: try !pinnable.isPinned,
                                         isUnreferenced: try node.hasNoOutputWires())
            }
        }
    }
}
