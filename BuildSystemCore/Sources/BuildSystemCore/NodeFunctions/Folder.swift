//
//  Folder.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

struct FolderManifestEntry: Codable {
    let name: String
    let isFolder: Bool
    let isPinned: Bool
}

struct FolderManifest: PolySerializable {
    static let kind: UInt = 4

    let baseFolderPath: String
    let entries: [FolderManifestEntry]
}

public struct Folder: InputlessNodeFunction, HasPath, Pinnable, UserDeletable {
    public static let kind: UInt = 1

    public static let inputFileSystemName = "input:"
    public static let outputFileSystemName = "output:"

    var embeddedNode: Node

    init(thisNode: Node) throws {
        embeddedNode = thisNode
        embeddedNode.name = name
        if embeddedNode.parentNodeID == nil {
            embeddedNode.parentNodeID = try resolveFolderID(path: containingPath)
        }
    }

    var inputFileSystem: Node {
        get throws {
            try Folder.inputFileSystem
        }
    }

    func canBePinned() -> Bool {
        // HACK
        containingPath.hasPrefix(.init(Folder.inputFileSystemName))
//        self.parentNodeFunction?.canBePin
    }

    func didCreate() throws -> ProcessOutput? {
        .init(outputValues: [Self.folderManifestOutputPort: .value(try buildManifest().toJSON().intern()),
                             Self.pinnedOutputPort: canBePinned() ? .noValue(reason: .error(message: "Deleted")) : .value("")], // HACK
              inputWireExpectations: [:])
    }

    var path: Path {
        .init(thisNode.properties["path"]!)
    }

    // Ignores the fact that a Node that has wires to/from it should never be deleted; that check needs to happen outside this
    func canBeDeleted() throws -> Bool {
        // TODO: slow
        try (thisNode.allChildren.filter { try !$0.nodeFunction().canBeDeleted() }).isEmpty && !(canBePinned() && isPinned)
    }

    // The manifest is a non-recursive list of immediate children
    static let folderManifestOutputPort = "manifest"

    // Nodes are not normally allowed to store state. A Folder in the input file system, however, needs to know if the user deleted it
    // (or never pushed it) but it has references from the graph -- called a ghost or "not pinned". StaticFiles represent this ghost
    // state by clearing their output value. So we use this "fake" (unlikely to be connected) output as a way to store this ghost/not-pinned state.
    static let pinnedOutputPort = "pinned"

    static let descriptor = NodeFunctionDescriptor(inputPorts: [], outputPorts: [folderManifestOutputPort, pinnedOutputPort])

    // when a child is added, we post a "child added" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    // when a child is deleted, we post a "child deleted" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    func onChildAdded(nodeID: ObjectID) throws {
        try refreshOutputs()
    }

    func onChildContentChanged(nodeID: ObjectID, name: String) throws {
        try refreshOutputs()
    }

    func onChildDeleted(nodeID: ObjectID) throws {
        try refreshOutputs()

        // Only self-delete when the folder is truly empty. Using canBeDeleted() here is wrong:
        // it returns true whenever all *remaining* children are individually deletable, which
        // causes premature self-deletion while other children still exist in the DB. When the
        // second child's cascade later calls notifyParentOfChildDeletion(), the parent is gone
        // and the lookup throws nodeNotFound, aborting the cascade and leaving orphaned nodes.
        if try thisNode.allChildren.isEmpty && !(canBePinned() && isPinned) && hasNoOutputWires() && hasNoInputWires() {
            try delete()
        }
    }

    public var isPinned: Bool {
        get throws {
            try !thisNode.readFromOutputPort(Self.pinnedOutputPort).isNoValue
        }
    }

    func setPinned(_ pinned: Bool) throws {
        if !canBePinned() && pinned {
            return
        }
        try thisNode.writeToOutputPort(Self.pinnedOutputPort,
                                       value: pinned ? .value("true".intern()) : .noValue(reason: .error(message: "Deleted/Nonexistent")))

        try notifyParentOfChildContentChange()
    }

    private func buildManifest() throws -> FolderManifest {
        var folderManifestEntries = [FolderManifestEntry]()

        for child in try thisNode.allChildren {
            let pinnable = try child.nodeFunction() as? Pinnable

            folderManifestEntries.append(.init(name: child.name!,
                                               isFolder: child.kind == Folder.kind,
                                               isPinned: (pinnable != nil) ? try pinnable!.isPinned : false))
        }

        return .init(baseFolderPath: path.string, entries: folderManifestEntries)
    }

    // Folder works outside the cache system and therefore cannot use "process". It is a Node with outputs, however.
    func refreshOutputs() throws {
        try thisNode.writeToOutputPort(Self.folderManifestOutputPort,
                                       value: .value(try buildManifest().toJSON().intern()))
    }

    public func deleteInInputFileSystem() throws {

        // Delete children or unpin them
        for child in try thisNode.allChildren {
            if let userDeletableChild = try child.nodeFunction() as? UserDeletable {
                try userDeletableChild.deleteInInputFileSystem()
            } else {
                throw NodeError.other(message: "Cannot delete Folder because one or more children are not deletable")
            }
        }

        try setPinned(false)

        if try hasNoOutputWires() && canBeDeleted() {
            try delete()
        }
    }
}

// MARK: - File system roots

extension Folder {

    /// The input file system's root Folder.
    ///
    /// These roots are a property of the graph, not of the engine: each is just the Folder
    /// node whose path is "input:" or "output:", found or created by shape like any other
    /// node. They live here rather than on BuildEngine so a node function does not have to
    /// reach for the engine — and so the engine is not a dependency of the layer below it.
    public static var inputFileSystem: Node {
        get throws { try root(named: inputFileSystemName) }
    }

    /// The output file system's root Folder.
    public static var outputFileSystem: Node {
        get throws { try root(named: outputFileSystemName) }
    }

    // BUG: this is extremely slow. TODO cache
    private static func root(named name: String) throws -> Node {
        let graphShape = GraphShapeNode(typeName: "Folder",
                                        args: [.init(key: "path", value: name)],
                                        inputs: [],
                                        outputs: [])
        let (rootNode, _) = try graphShape.findOrCreateMatchingNode()
        return rootNode
    }
}
