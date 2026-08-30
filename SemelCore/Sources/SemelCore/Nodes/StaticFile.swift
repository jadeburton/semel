//
//  StaticFile.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import SemelNodeKit

public protocol Pinnable {
    var isPinned: Bool { get throws }
}

public protocol UserDeletable {
    func deleteInInputFileSystem() throws
}

// StaticFile only exists within the input file system hierarchy. It provides a connection to the outside world,
// allowing users to push files into the build system and have them be used as inputs to other Nodes. It is a leaf
// node and cannot have inputs.
public struct StaticFile: Node, FileType, HasPath, Pinnable, UserDeletable {
    public static let kind: UInt = 3

    public var isPinned: Bool {
        get throws {
            guard let nodeValue = try read() else {
                return false
            }

            return !nodeValue.isNoValue
        }
    }

    static let outputPort = "output"

    public var thisNode: NodeRecord

    var path: Path {
        Path(thisNode.properties["path"]!)
    }

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
        assert(!path.string.contains(Folder.outputFileSystemName))
        try placeInFileSystem()
    }

    public static let descriptor = NodeDescriptor(inputPorts: [], outputPorts: [outputPort])

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

    public func replaceContent(_ content: DataObjectHash?) throws -> Bool {
        let changed: Bool

        if let content {
            changed = try thisNode.writeToOutputPort(Self.outputPort, value: .value(content))
        } else {
            changed = try thisNode.writeToOutputPort(Self.outputPort, value: .noValue(reason: .error(messageDataObjectHash: "Deleted".intern())))
        }

        if changed {
            try notifyParentOfChildContentChange()
        }

        return changed
    }

    public func deleteInInputFileSystem() throws {
        _ = try replaceContent(nil)

        // Defer physical deletion to the idle-time GC (processPendingDeletions) rather
        // than deleting immediately.  This matters when the engine hasn't yet wired this
        // file to its consumers (ClangCompilerTool etc.) — in that window hasNoOutputWires()
        // would be true even though the file IS referenced, causing the node to be destroyed
        // instead of remaining as a [missing] ghost.  connectWire() automatically clears
        // the pendingDeletion flag if a wire is later connected, rescuing the node.
        if try hasNoOutputWires() {
            try database.node.updatePendingDeletion(nodeID: (try requireID()), pendingDeletion: true)
        }
    }
}

public protocol FileType {
    func read() throws -> NodeValue?
}
