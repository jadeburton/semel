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
    static let outputPort = "output"
    /// The mode the file was pushed with, so a tree or a product built from it keeps it.
    static let fileMetadataOutputPort = FileMetadata.portName

    public var thisNode: NodeRecord

    var path: Path {
        Path(thisNode.properties[Self.pathProperty]!)
    }

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
        assert(!path.string.contains(Folder.outputFileSystemName))
        try placeInFileSystem()
    }

    public static let descriptor = NodeDescriptor(inputPorts: [], outputPorts: [outputPort, fileMetadataOutputPort])

    /// Never reached in a working graph: a node declaring no input ports is not scheduled,
    /// so nothing asks it to process. An ordinary error rather than a trap — a node is not
    /// the right place to enforce the engine's invariants, and a third-party one should not
    /// be able to bring the process down.
    public func process(input: ProcessInput) throws -> ProcessOutput {
        throw NodeError.other(message: "\(Self.self) declares no input ports and cannot process")
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

    /// The bytes on `output` and the mode on `fileMetadata`. Returns whether either
    /// changed: a file made executable under the same bytes is a push that changes what a
    /// tree or a product built from it holds.
    public func replaceContent(_ content: DataObjectHash, mode: UInt16) throws -> Bool {
        let metadataChanged = try thisNode.writeToOutputPort(Self.fileMetadataOutputPort,
                                                             value: try Self.metadataValue(mode: mode))
        return try replaceContentWith(.value(content)) || metadataChanged
    }

    /// The bytes alone. Only they are the folder's business: a content root folds content
    /// and not modes.
    private func replaceContentWith(_ value: NodeValue) throws -> Bool {
        let changed = try thisNode.writeToOutputPort(Self.outputPort, value: value)
        if changed {
            try notifyParentOfChildContentChange()
        }
        return changed
    }

    static func metadataValue(mode: UInt16) throws -> NodeValue {
        .value(try FileMetadata(mode: mode).jsonString().intern())
    }

    /// A file nobody has pushed yet says so on `output` alone, and has the default mode on
    /// `fileMetadata`. Its state is one thing to report, not one per port; and a removed
    /// file keeps the mode it was last pushed with for the same reason. What reads a mode
    /// reads it beside the bytes, whose state is the one that stops it.
    public func didCreate() throws -> ProcessOutput? {
        .init(outputValues: [Self.outputPort:             .noValue(reason: .initializing),
                             Self.fileMetadataOutputPort: try Self.metadataValue(mode: FileMetadata.defaultMode)],
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

public protocol FileType {
    func read() throws -> NodeValue?
}
