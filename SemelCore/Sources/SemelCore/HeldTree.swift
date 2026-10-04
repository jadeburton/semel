// HeldTree.swift
// SemelCore
//
// What the input file system holds below a folder, read for a client deciding what a push
// has to send (B-132). The client folds the disk as the engine folds what it holds
// (`FolderOnDisk`), compares the two folder by folder, and sends only where they differ.

import Foundation
import SemelDatabaseModels
import SemelNodeKit

public enum HeldTree {

    /// One folder the input file system holds, and the content root it publishes.
    public struct FolderRoot: Equatable {
        /// Relative to the input file system's root, as a push names it.
        public let path: Path
        /// The folder's content root, or nil when it cannot be taken as current: the folder
        /// or one below it is marked for a fold it has not had yet, so the root does not
        /// yet say what the folder holds. A client compares nothing against it and looks
        /// at the folder's children instead.
        public let contentRoot: DataObjectHash?
        /// Whether the folder is pinned, as a push leaves every folder on the way to a file.
        /// A root is only compared on a pinned folder: an unpinned one is one a push still
        /// has to pin, and a ghost's root folds what nobody pushed.
        public let isPinned: Bool
        /// The dot-named files the folder holds a value for, by name (B-77 item 5). A push
        /// walking a folder leaves every dot-name out, so these are in the engine's root and
        /// not in a fold of the disk unless the client is told: a file a formula named
        /// exactly, which `push` of its path and `build`'s follow of a missing source push
        /// whatever its name. The client folds each one it finds on disk, so the two roots
        /// agree, and a push of the folder sends it again when it changes.
        public let hiddenFiles: [String]

        public init(path: Path, contentRoot: DataObjectHash?, isPinned: Bool, hiddenFiles: [String] = []) {
            self.path        = path
            self.contentRoot = contentRoot
            self.isPinned    = isPinned
            self.hiddenFiles = hiddenFiles
        }
    }

    /// The folder at `relativePath` in the input file system and every folder below it, in
    /// one read of the graph: parents before their children, nothing when there is no
    /// folder at the path.
    ///
    /// Three queries, however large the tree: the folders with their roots and pins, the
    /// dot-named files they hold, and the marks that say which roots are waiting to be
    /// folded again. All are read in one
    /// snapshot, and each fold clears its mark and marks the folder above in one savepoint
    /// of one transaction (`Folder.flushDirtyManifests`), so a root that is not marked is
    /// current as of this read — which is what lets a client skip a whole subtree on it.
    public static func folderRoots(below relativePath: Path) throws -> [FolderRoot] {
        let database: DatabaseLayer = DatabaseLayer.shared
        let contentRootPort         = Folder.contentRootOutputPort.asSymbolID()
        let pinnedPort              = Folder.pinnedOutputPort.asSymbolID()
        let markPrefix              = Folder.contentRootDirtyKeyPrefix

        return try readingFolder(at: relativePath, orElse: []) { folderID in
            let rows = try database.node.selectSubtree(below: folderID, kind: Folder.kind,
                                                       portSymbolIDs: [contentRootPort, pinnedPort])
            let marked = try database.metadata.selectKeys(withPrefix: markPrefix)
                .compactMap { ObjectID($0.dropFirst(markPrefix.count)) }
            var hiddenFilesByFolder: [ObjectID: [String]] = [:]
            for hidden in try database.node.selectDotNamedChildren(below: folderID, folderKind: Folder.kind,
                                                                   childKind: StaticFile.kind,
                                                                   withValueOn: StaticFile.outputPort.asSymbolID()) {
                hiddenFilesByFolder[hidden.parentNodeID, default: []].append(hidden.name)
            }

            var pathByID:   [ObjectID: Path]     = [:]
            var parentByID: [ObjectID: ObjectID] = [:]
            for row in rows {
                guard row.depth > 0 else {
                    pathByID[row.id] = relativePath
                    continue
                }
                guard let parentNodeID = row.parentNodeID, let parentPath = pathByID[parentNodeID], let name = row.name else {
                    continue
                }
                pathByID[row.id]   = parentPath / name
                parentByID[row.id] = parentNodeID
            }

            // A marked folder's root is stale, and so is every root above it, which folds it.
            var stale = Set<ObjectID>()
            for markedID in marked where pathByID[markedID] != nil {
                var current: ObjectID? = markedID
                while let nodeID = current, stale.insert(nodeID).inserted {
                    current = parentByID[nodeID]
                }
            }

            return rows.compactMap { row in
                guard let path = pathByID[row.id] else {
                    return nil
                }
                var contentRoot: DataObjectHash?
                if !stale.contains(row.id), let port = row.ports[contentRootPort], port.valueKind == .value {
                    contentRoot = port.dataObjectHash
                }
                return FolderRoot(path: path, contentRoot: contentRoot,
                                  isPinned: row.ports[pinnedPort]?.valueKind == .value,
                                  hiddenFiles: hiddenFilesByFolder[row.id] ?? [])
            }
        }
    }

    /// One child of a folder, as a push compares it with the disk.
    public struct Child: Equatable {
        public enum Kind: Equatable {
            case file
            case folder
        }

        public let name: String
        public let kind: Kind
        /// For a file holding a value, the hash of its bytes; nil for one nobody pushed or
        /// one that was removed, which a push has to send whatever it holds.
        public let contentHash: DataObjectHash?
        /// For a file holding a value, the mode it was pushed with.
        public let mode: UInt16?
        /// What the child holds as a symbolic link pushed as one, file or folder.
        public let symbolicLinkTarget: String?
        /// A file holding a value, or a folder that is pinned: what a push leaves.
        public let isPinned: Bool
    }

    /// The children of the folder at `relativePath` in the input file system, in one read
    /// of the graph, or nil when there is no folder there. A query per port, whatever the
    /// number of children, and each distinct metadata document read once.
    public static func children(ofFolderAt relativePath: Path) throws -> [Child]? {
        let database: DatabaseLayer = DatabaseLayer.shared
        let contentPort             = StaticFile.outputPort.asSymbolID()
        let metadataPort            = StaticFile.fileMetadataOutputPort.asSymbolID()
        let pinnedPort              = Folder.pinnedOutputPort.asSymbolID()
        let linkPort                = Folder.symbolicLinkOutputPort.asSymbolID()

        return try readingFolder(at: relativePath, orElse: nil) { folderID -> [Child]? in
            let summaries = try database.node.selectChildSummaries(parentNodeID: folderID)
            let contents  = try database.node.selectChildPorts(parentNodeID: folderID, nameSymbolID: contentPort)
            let metadatas = try database.node.selectChildPorts(parentNodeID: folderID, nameSymbolID: metadataPort)
            let pins      = try database.node.selectChildPorts(parentNodeID: folderID, nameSymbolID: pinnedPort)
            let links     = try database.node.selectChildPorts(parentNodeID: folderID, nameSymbolID: linkPort)

            var documents: [DataObjectHash: String] = [:]
            func document(_ port: OutputPort?) throws -> String? {
                guard let port, port.valueKind == .value, let hash = port.dataObjectHash, !hash.isEmpty else {
                    return nil
                }
                if let known = documents[hash] {
                    return known
                }
                let text = try hash.resolveAsString()
                documents[hash] = text
                return text
            }

            var children: [Child] = []
            for summary in summaries {
                guard let name = summary.name else {
                    continue
                }
                switch summary.kind {
                case StaticFile.kind:
                    let metadata = try document(metadatas[summary.id]).flatMap(FileMetadata.decode(from:))
                    var contentHash: DataObjectHash?
                    if let port = contents[summary.id], port.valueKind == .value {
                        contentHash = port.dataObjectHash
                    }
                    children.append(Child(name: name, kind: .file, contentHash: contentHash,
                                          mode: contentHash == nil ? nil : metadata?.mode ?? FileMetadata.defaultMode,
                                          symbolicLinkTarget: metadata?.symbolicLinkTarget,
                                          isPinned: contentHash != nil))
                case Folder.kind:
                    let target = try document(links[summary.id])
                    children.append(Child(name: name, kind: .folder, contentHash: nil, mode: nil,
                                          symbolicLinkTarget: target?.isEmpty == false ? target : nil,
                                          isPinned: pins[summary.id]?.valueKind == .value))
                default:
                    continue
                }
            }
            return children
        }
    }

    /// Where a folder lookup landed: on a folder, on nothing, or on a root id the cache held
    /// for a node that is no longer the input root.
    private enum FolderLookup {
        case found(ObjectID)
        case absent
        case staleRoot
    }

    /// Runs `read` in one snapshot with the folder at `relativePath` found for it, trying
    /// first with the root id the cache holds — checked in the same query that finds the
    /// folder, as a push checks it — and once more with the root looked up afresh, which
    /// may have to create it and so happens outside any snapshot.
    private static func readingFolder<Result>(at relativePath: Path, orElse absent: Result,
                                              _ read: (ObjectID) throws -> Result) throws -> Result {
        let database: DatabaseLayer = DatabaseLayer.shared
        var rootID                  = try Folder.cachedInputFileSystemID ?? Folder.inputFileSystem.requireID()
        for attempt in 0..<2 {
            if attempt > 0 {
                rootID = try Folder.inputFileSystem.requireID()
            }
            let outcome: Result? = try database.withReadSnapshot {
                switch try lookUpFolder(at: relativePath, belowRootID: rootID) {
                case .found(let folderID): return try read(folderID)
                case .absent:              return absent
                case .staleRoot:           return nil
                }
            }
            if let outcome {
                return outcome
            }
        }
        return absent
    }

    /// The folder at `relativePath` below `rootID`, in one query (`selectPath`) that also
    /// reads the root's row to check it is still the input root.
    private static func lookUpFolder(at relativePath: Path, belowRootID rootID: ObjectID) throws -> FolderLookup {
        guard !relativePath.isEmpty else {
            let root = try DatabaseLayer.shared.node.find(nodeID: rootID)
            return root.map { Folder.isRoot($0, named: Folder.inputFileSystemName) } == true ? .found(rootID) : .staleRoot
        }
        let steps = try DatabaseLayer.shared.node.selectPath(below: rootID, names: relativePath.segments, portSymbolIDs: [])
        guard let root = steps.first, root.depth == 0, Folder.isRoot(root.node, named: Folder.inputFileSystemName) else {
            return .staleRoot
        }
        guard steps.count == relativePath.count + 1,
              steps.enumerated().allSatisfy({ $0.element.depth == $0.offset }),
              let folder = steps.last, folder.node.kind == Folder.kind, let folderID = folder.node.id else {
            return .absent
        }
        return .found(folderID)
    }
}
