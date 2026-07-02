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
}

struct FolderManifest: PolySerializable {
    static let kind: UInt = 4

    let entries: [FolderManifestEntry]
}

struct Folder: InputlessNodeFunction, HasPath {
    static let kind: UInt = 1

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
        embeddedNode!.name = name

        // input: thisNode.properties["path"] = "inputFileSystem/src" name = "src", containingPath = "inputFileSystem"
        // parentNodeID = the folder that corresponds to containingPath, creating it if necessary.
        // root folder ID is always either outputFileSystem or inputFileSystem, depending on which one the containingPath starts with.

        embeddedNode!.parentNodeID = try resolveFolderID(path: containingPath)

//        if embeddedNode!.parentNodeID == nil {
//            // This is the root folder, which has no parent. The root folder's ID is either inputFileSystem or outputFileSystem.
//            embeddedNode!.parentNodeID = try resolveFolderID(path: name)
//        }
    }

    private func resolveFolderID(path: String) throws -> ObjectID? {
        guard !path.isEmpty else {
            // "" -> nil because it is the root folder, which has no parent.
            return nil
        }

        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        // The first component must be "inputFileSystem" or "outputFileSystem"
        guard let rootName = components.first else {
            throw NodeError.other(message: "Path '\(path)' has no components")
        }

        let rootNode: Node
        switch rootName {
        case "inputFileSystem":
            rootNode = try BuildEngine.shared.inputFileSystem
        case "outputFileSystem":
            rootNode = try BuildEngine.shared.outputFileSystem
        default:
            throw NodeError.other(message: "Path '\(path)' must begin with 'inputFileSystem' or 'outputFileSystem', got '\(rootName)'")
        }

        // If the path is just the root (e.g. "inputFileSystem"), return the root folder's ID
        let subPath = components.dropFirst().joined(separator: "/")
        guard !subPath.isEmpty else {
            return rootNode.id!
        }

        // Walk (creating as needed) the remaining components beneath the root folder
        let resolvedFolder = try rootNode.ensureEntirePathExistsAsFolders(subPath)
        return resolvedFolder.id!
    }

    var inputFileSystem: Node {
        get throws {
            try BuildEngine.shared.inputFileSystem
        }
    }

    func didCreate() throws -> ProcessOutput? {
        .init(outputValues: [Self.folderManifestOutputPort: .value(try buildManifest().toJSON().intern())],
              inputWireExpectations: [:])
    }

    var path: String {
        thisNode.properties["path"]!
    }

    func canBeDeleted() throws -> Bool {
        try thisNode.allChildren.isEmpty
    }

    // The manifest is a non-recursive list of immediate children
    static let folderManifestOutputPort = "manifest"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [folderManifestOutputPort], dynamicInputPorts: [])

    // when a child is added, we post a "child added" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    // when a child is deleted, we post a "child deleted" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    //
    func notifyChildAdded(newChildNode: Node) throws {
        try refreshOutputs()
    }

    func notifyChildContentChanged(nodeID: ObjectID, name: String) throws {
        try refreshOutputs()
    }

    private func buildManifest() throws -> FolderManifest {
        var folderManifestEntries = [FolderManifestEntry]()

        for child in try thisNode.allChildren {

            // Hide ghosts
            if let staticFile = try child.nodeFunction() as? StaticFile {
                if try staticFile.isGhost() {
                    continue
                }
            }

            folderManifestEntries.append(.init(name: child.name!, isFolder: child.kind == Folder.kind))
        }

        return .init(entries: folderManifestEntries)
    }

    // Folder works outside the cache system and therefore cannot use "process". It is a Node with outputs, however.
    func refreshOutputs() throws {
        try thisNode.writeToOutputPort(Self.folderManifestOutputPort,
                                       value: .value(try buildManifest().toJSON().intern()))
    }
}
