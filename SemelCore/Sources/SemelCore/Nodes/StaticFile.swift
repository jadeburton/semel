//
//  StaticFile.swift
//  semel
//
//  Created by Jade Burton on 22.02.26.
//

import SemelNodeKit

public protocol Pinnable {
    /// The port value the pin is read from: a node is pinned when that port carries a
    /// value, and when it does not, the reason is what a listing has to say about it.
    var pinnedValue: NodeValue? { get throws }

    /// What a listing says about this node. A requirement rather than a convenience, so
    /// that a type whose port says something on another node's behalf can answer for
    /// itself — which is what an artifact, pinned by an input, has to do.
    var listedState: FileWildcardEntryState { get throws }
}

extension Pinnable {
    public var isPinned: Bool {
        get throws {
            guard let pinnedValue = try pinnedValue else {
                return false
            }
            return !pinnedValue.isNoValue
        }
    }

    /// A node's own port is its own state: a name with no port behind it at all has had
    /// nothing produced for it.
    public var listedState: FileWildcardEntryState {
        get throws {
            try pinnedValue.map(FileWildcardEntryState.init) ?? .notProduced
        }
    }
}

public protocol UserDeletable {
    func deleteInInputFileSystem() throws
}

// StaticFile only exists within the input file system hierarchy. It provides a connection to the outside world,
// allowing users to push files into the build system and have them be used as inputs to other Nodes. It is a leaf
// node and cannot have inputs.
public struct StaticFile: Node, FileType, HasPath, Pinnable, UserDeletable, FileMetadataProvider {
    public static let kind: UInt = 3

    /// A source's own port, which is also the one it is pinned by. Having no inputs, it is
    /// never scheduled and nothing above it can fail, so a source shows three states and no
    /// others: the value the user pushed, `deleted` once they take it away, and the state of
    /// a value nobody has produced while the graph names a file nobody pushed.
    public var pinnedValue: NodeValue? {
        get throws {
            try read()
        }
    }

    public static let pathProperty = "path"
    /// The bytes a reader of the path gets. For a symbolic link, the bytes of the file it
    /// names, so that what reads a file through this port reads a link as it did when a
    /// push followed every link (B-77); a link to a folder is a `Folder`.
    static let outputPort = "output"
    /// The mode the file was pushed with, so a tree or a product built from it keeps it;
    /// and for a symbolic link its target, which is what makes it one (B-77).
    static let fileMetadataOutputPort = FileMetadata.portName

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
        let inputPath = try self.path
        assert(!inputPath.string.contains(Folder.outputFileSystemName))
        try placeInFileSystem()
    }

    public static let descriptor = NodeDescriptor(inputPorts: [], outputPorts: [outputPort, fileMetadataOutputPort])

    /// Never reached in a working graph: a node declaring no input ports is not scheduled,
    /// so nothing asks it to process. An ordinary error rather than a trap — a node is not
    /// the right place to enforce the engine's invariants, and a third-party one should not
    /// be able to bring the process down.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        throw NodeError.sourceCannotProcess(type: "\(Self.self)")
    }


    // If StaticFile has content set, it must not be deleted even when there are no output Wires. However, if
    // it has no content set (i.e. the user never pushed the file, or they deleted it) then it can be deleted
    // if there are no output Wires.
    public func canBeDeleted() throws -> Bool {
        try !isPinned
    }

    public func read() throws -> NodeValue? {
        try thisNode.readFromOutputPort(Self.outputPort)
    }

    /// Content with the default mode, or the removal of the file when `content` is nil.
    public func replaceContent(_ content: DataObjectHash?) throws -> Bool {
        guard let content else {
            return try replaceContentWith(.noValue(reason: .deleted))
        }
        return try replaceContent(content, mode: FileMetadata.defaultMode)
    }

    /// The bytes on `output` and the mode — and for a symbolic link its target — on
    /// `fileMetadata`. Returns whether either changed: a file made executable under the same
    /// bytes is a push that changes what a tree or a product built from it holds.
    public func replaceContent(_ content: DataObjectHash, mode: UInt16, symbolicLinkTarget: String? = nil) throws -> Bool {
        try replaceContent(content, metadata: try Self.metadataValue(mode: mode, symbolicLinkTarget: symbolicLinkTarget))
    }

    /// The same, with the metadata document already interned: a push interns it once, for
    /// the file it may create and for this.
    func replaceContent(_ content: DataObjectHash, metadata: NodeValue) throws -> Bool {
        let metadataChanged = try thisNode.writeToOutputPort(Self.fileMetadataOutputPort, value: metadata)
        let contentChanged  = try replaceContentWith(.value(content), notifying: metadataChanged)
        return contentChanged || metadataChanged
    }

    /// The bytes. They are the folder's business, and so is the metadata when it changed:
    /// a content root folds what a link says and a file's mode, both on the metadata.
    private func replaceContentWith(_ value: NodeValue, notifying metadataChanged: Bool = false) throws -> Bool {
        let changed = try thisNode.writeToOutputPort(Self.outputPort, value: value)
        if changed || metadataChanged {
            try notifyParentOfChildContentChange()
        }
        return changed
    }

    static func metadataValue(mode: UInt16, symbolicLinkTarget: String? = nil) throws -> NodeValue {
        .value(try metadataDocument(mode: mode, symbolicLinkTarget: symbolicLinkTarget).intern())
    }

    /// What `metadataValue` interns: the document a mode, and a link's target, are stored as.
    private static func metadataDocument(mode: UInt16, symbolicLinkTarget: String?) throws -> String {
        try FileMetadata(mode: mode, symbolicLinkTarget: symbolicLinkTarget).jsonString()
    }

    /// A file nobody has pushed yet says so on `output` alone, and has the default mode on
    /// `fileMetadata`. Its state is one thing to report, not one per port; and a removed
    /// file keeps the mode it was last pushed with for the same reason. What reads a mode
    /// reads it beside the bytes, whose state is the one that stops it.
    public func didCreate() throws -> ProcessOutput? {
        didCreate(metadata: try Self.metadataValue(mode: FileMetadata.defaultMode))
    }

    /// The same, with the metadata a push is about to give the file: made with it, the file
    /// has its metadata document interned once, where made with the default and then given
    /// the push's it was interned twice — the default's touched again on every new file.
    func didCreate(metadata: NodeValue) -> ProcessOutput {
        .init(outputValues: [Self.outputPort:             .noValue(reason: .initializing),
                             Self.fileMetadataOutputPort: metadata],
              inputWireSpecs: [:])
    }

    public func readFileMetadata() throws -> FileMetadata? {
        guard case .value(let hash) = try thisNode.readFromOutputPort(Self.fileMetadataOutputPort) else {
            return nil
        }
        return FileMetadata.decode(from: try hash.resolveAsString())
    }

    public func deleteInInputFileSystem() throws {
        _ = try replaceContent(nil)

        // Defer physical deletion to the idle-time GC (processPendingDeletions) rather
        // than deleting immediately.  This matters when the engine hasn't yet wired this
        // file to its consumers (ClangCompiler etc.) — in that window hasNoOutputWires()
        // would be true even though the file IS referenced, causing the node to be destroyed
        // instead of remaining as a [deleted] ghost.  connectWire() automatically clears
        // the pendingDeletion flag if a wire is later connected, rescuing the node.
        if try hasNoOutputWires() {
            try database.node.updatePendingDeletion(nodeID: (try requireID()), pendingDeletion: true)
        }
    }
}

// MARK: - Pushing

extension StaticFile {

    /// Stores `content` with `mode` at `relativePath` in the input file system, creating
    /// the folders on the way to it pinned. Returns whether the bytes or the mode changed.
    ///
    /// A push of a tree sends every file in it, and on a tree nobody edited every one of
    /// them is already there, so that case is answered first, and with one select however
    /// deep the file is: the root, the path below it with the folders' pins, and the file's
    /// two ports, in one query (`isHeld`). The bytes are only hashed for it, not stored and
    /// not touched — the port that holds them already keeps the object alive, and a
    /// collection sees that port whenever it began. Anything short of that — a folder
    /// missing or unpinned, a file new or different, a root the cache does not know — takes
    /// the full path, which is the only one that writes (B-131).
    ///
    /// A symbolic link is pushed with its `symbolicLinkTarget` and the bytes of what it
    /// names (B-77).
    public static func push(_ bytes: [UInt8], mode: UInt16, symbolicLinkTarget: String? = nil,
                            at relativePath: Path) throws -> Bool {
        try push(contentHash: bytes.internedHash, storing: { try bytes.intern() },
                 mode: mode, symbolicLinkTarget: symbolicLinkTarget, at: relativePath)
    }

    /// `push` for bytes already in the object store under `contentHash`, so that what calls
    /// this hashes and stores nothing and touches only the graph. The server interns a
    /// push's bytes before the one queue that writes the graph, on every core, and hands
    /// that queue the hash; the answer and the rows are the ones `push` gives for the
    /// bytes.
    public static func push(interned contentHash: DataObjectHash, mode: UInt16, symbolicLinkTarget: String? = nil,
                            at relativePath: Path) throws -> Bool {
        try push(contentHash: contentHash, storing: { contentHash },
                 mode: mode, symbolicLinkTarget: symbolicLinkTarget, at: relativePath)
    }

    /// The one push both of the above are. `storing` puts the bytes in the store and names
    /// them `contentHash`; it is called only on the path that writes.
    private static func push(contentHash: DataObjectHash, storing: () throws -> DataObjectHash,
                             mode: UInt16, symbolicLinkTarget: String?, at relativePath: Path) throws -> Bool {
        let fullPath = Path(Folder.inputFileSystemName) / relativePath
        let specNode = GraphSpecNode(StaticFile.self, properties: [pathProperty: fullPath.string])

        if let rootID = Folder.cachedInputFileSystemID {
            let metadataHash = try metadataDocument(mode: mode, symbolicLinkTarget: symbolicLinkTarget).internedHash
            let pushed = PushedFile(identity:         try specNode.identity(),
                                    content:          .value(contentHash),
                                    metadata:         .value(metadataHash),
                                    pinnedSymbolID:   Folder.pinnedOutputPort.asSymbolID(),
                                    contentSymbolID:  outputPort.asSymbolID(),
                                    metadataSymbolID: fileMetadataOutputPort.asSymbolID())
            // The objects are asked after too, a look rather than a write: a store that lost
            // one the graph still names is mended by pushing the file again, as it always was.
            if try isHeld(pushed, at: relativePath, belowRootID: rootID),
               [contentHash, metadataHash].allSatisfy({ $0.isEmpty || DataObjectStore.shared.exists(hash: $0) }) {
                return false
            }
        }

        let root = try Folder.inputFileSystem
        let parentFolder = try root.ensureEntirePathExistsAsFolders(relativePath.deletingLastComponent ?? .empty,
                                                                    pinned: true, forAChild: true)

        let metadata = try metadataValue(mode: mode, symbolicLinkTarget: symbolicLinkTarget)
        let (found, _) = try specNode.findOrCreateMatchingNode(outputIfCreated: { node in
            (node as? StaticFile)?.didCreate(metadata: metadata)
        })
        let fromNode = try adopt(found, into: parentFolder)
        guard let staticFile = try fromNode.nodeAsAny() as? StaticFile else {
            throw NodeError.nameCollision(path: fullPath.string, existingKind: fromNode.kind)
        }
        return try staticFile.replaceContent(try storing(), metadata: metadata)
    }

    /// Makes `folder` the parent of the file node `nodeRecord`, when it is not already.
    ///
    /// The removal of a folder takes the folder's own row as soon as nothing below it is
    /// pinned, and leaves its files to the collector, marked: until the next idle they name
    /// a parent that is gone. A push of one of them in that window finds the file by its
    /// identity under the folder the push has just made again, and that folder is its
    /// parent now — the one its change is told to, the one whose root folds it.
    /// Returns the record as it now stands.
    static func adopt(_ nodeRecord: NodeRecord, into folder: NodeRecord) throws -> NodeRecord {
        let folderID = try folder.requireID()
        guard nodeRecord.kind == StaticFile.kind, nodeRecord.parentNodeID != folderID else {
            return nodeRecord
        }
        var adopted = nodeRecord
        adopted.parentNodeID = folderID
        try DatabaseLayer.shared.node.update(adopted)
        try adopted.makeNode().notifyParentThisChildAdded()
        return adopted
    }

    /// What one push would leave in the graph, worked out before anything is read.
    private struct PushedFile {
        let identity:         String
        let content:          NodeValue
        let metadata:         NodeValue
        let pinnedSymbolID:   ObjectID
        let contentSymbolID:  ObjectID
        let metadataSymbolID: ObjectID
    }

    /// Whether the graph already holds `pushed` at `relativePath`, so that pushing it would
    /// write nothing: the cached root id still names the input root, every folder on the
    /// way is there once, is a folder and is pinned, and the file is there once, under the
    /// identity the full path would find it by, with exactly the rows `replaceContent` would
    /// write on its two ports. One query (`selectPath`).
    ///
    /// Only ever a shortcut to the answer `false`. Each condition is one under which the
    /// full path would find what it looks for and write nothing — it creates no folder,
    /// pins none, and `writeToOutputPort` compares the same rows and returns — so taking the
    /// shortcut skips reads and not work. A condition this cannot prove is left to the full
    /// path to find out, so a graph this does not understand is never read as unchanged.
    private static func isHeld(_ pushed: PushedFile, at relativePath: Path, belowRootID rootID: ObjectID) throws -> Bool {
        let names = relativePath.segments
        guard !names.isEmpty else {
            return false
        }

        let pinnedSymbolID   = pushed.pinnedSymbolID
        let contentSymbolID  = pushed.contentSymbolID
        let metadataSymbolID = pushed.metadataSymbolID

        let steps = try DatabaseLayer.shared.node.selectPath(below: rootID, names: names,
                                                             portSymbolIDs: [pinnedSymbolID, contentSymbolID, metadataSymbolID])

        // The root, then one node per depth, and so one chain: two children of one name
        // anywhere on the way is a graph the full path refuses, and it should be the one to
        // say so.
        guard steps.count == names.count + 1,
              steps.enumerated().allSatisfy({ $0.element.depth == $0.offset }),
              let root = steps.first, Folder.isRoot(root.node, named: Folder.inputFileSystemName),
              let file = steps.last else {
            return false
        }

        for folder in steps.dropFirst().dropLast() {
            guard folder.node.kind == Folder.kind,
                  let pinned = folder.ports[pinnedSymbolID],
                  try !pinned.asNodeValue().isNoValue else {
                return false
            }
        }

        guard file.node.kind == StaticFile.kind, file.node.identity == pushed.identity else {
            return false
        }
        let fileNodeID = try file.node.requireID()
        return try file.ports[contentSymbolID]  == pushed.content.asOutputPort(nodeID: fileNodeID, outputSymbolID: contentSymbolID)
            && file.ports[metadataSymbolID] == pushed.metadata.asOutputPort(nodeID: fileNodeID, outputSymbolID: metadataSymbolID)
    }
}

public protocol FileType {
    func read() throws -> NodeValue?
}
