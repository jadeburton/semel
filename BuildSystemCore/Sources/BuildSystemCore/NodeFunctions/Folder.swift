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

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
        embeddedNode!.name = name
        if embeddedNode!.parentNodeID == nil {
            embeddedNode!.parentNodeID = try resolveFolderID(path: containingPath)
        }
    }

    var inputFileSystem: Node {
        get throws {
            try BuildEngine.shared.inputFileSystem
        }
    }

    func canBePinned() -> Bool {
        // HACK
        containingPath.hasPrefix("inputFileSystem")
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
        try thisNode.allChildren.isEmpty && !(canBePinned() && isPinned)
    }

    // The manifest is a non-recursive list of immediate children
    static let folderManifestOutputPort = "manifest"

    // Nodes are not normally allowed to store state. A Folder in the input file system, however, needs to know if the user deleted it
    // (or never pushed it) but it has references from the graph -- called a ghost or "not pinned". StaticFiles represent this ghost
    // state by clearing their output value. So we use this "fake" (unlikely to be connected) output as a way to store this ghost/not-pinned state.
    static let pinnedOutputPort = "pinned"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [],
                                            outputPorts: [folderManifestOutputPort, pinnedOutputPort])

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

        if try canBeDeleted() && hasNoOutputWires() && hasNoInputWires() {
            try delete()
        }
    }

    var isPinned: Bool {
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

    func deleteInInputFileSystem() throws {

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
