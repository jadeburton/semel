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

struct Folder: InputlessNodeFunction {
    static let kind: UInt = 1

    enum CodingKeys: CodingKey {
    }

    func didCreate(node: Node) throws -> ProcessOutput {
        .init(outputValues: [Self.folderManifestOutputPort: .value(try FolderManifest(entries: []).toJSON().intern())],
              inputWireExpectations: [:])
    }

    func canBeDeleted(thisNode: Node) throws -> Bool {
        try hasNoOutputWires(thisNode: thisNode) && thisNode.allChildren.isEmpty
    }

    // The manifest is a non-recursive list of immediate children
    static let folderManifestOutputPort = "manifest"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [], outputPorts: [folderManifestOutputPort], dynamicInputPorts: [])

    // when a child is added, we post a "child added" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    // when a child is deleted, we post a "child deleted" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    //
    func notifyChildAdded(nodeID: ObjectID, name: String, thisNode: Node) throws {
        try refreshOutputs(thisNode: thisNode)
    }

    func notifyChildContentChanged(nodeID: ObjectID, name: String, thisNode: Node) throws {
        try refreshOutputs(thisNode: thisNode)
    }

    @discardableResult
    func ensureEntirePathExists(_ path: String, thisNode: Node) throws -> Node {

        // if input is a/b/c, we create a, if it does not already exist, then b, then c, and return the nodeID of c
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var currentFolder = thisNode

        for name in components {
            if let existingChild = try currentFolder.childNode(path: name) {
                currentFolder = existingChild
            } else {
                let newFolder = try currentFolder.childNode(path: name, kind: Folder.kind, createIfNotExist: true, properties: [:])!
                try (currentFolder.nodeFunctionCast() as Folder).notifyChildAdded(nodeID: newFolder.id!, name: name, thisNode: currentFolder)
                currentFolder = newFolder
            }
        }

        return currentFolder
    }

    func addOrReplaceChild(thisNode: Node, content: DataObjectHash, name: String) throws {
        assert(!name.contains("\\"))

        if let existingChild = try thisNode.childNode(path: name) {
            if let nodeFunction = try existingChild.nodeFunction() as? StaticFile {
                if try nodeFunction.replaceContent(thisNode: existingChild, content) {
                    try notifyChildContentChanged(nodeID: existingChild.id!, name: existingChild.name!, thisNode: thisNode)
                }
            } else {
                // TODO: what if the type is not StaticFileNode
            }
        } else {
            var newChild = try thisNode.childNode(path: name, kind: StaticFile.kind, createIfNotExist: true, properties: nil)!
            let staticFile = StaticFile()
            try newChild.setNodeFunction(staticFile)
            if try staticFile.replaceContent(thisNode: newChild, content) {
                try DatabaseLayer.shared.updateNode(newChild)
                try notifyChildAdded(nodeID: newChild.id!, name: newChild.name!, thisNode: thisNode)
            }
        }
    }

    private func buildManifest(thisNode: Node) throws -> FolderManifest {
        var folderManifestEntries = [FolderManifestEntry]()
        for child in try thisNode.allChildren {
            folderManifestEntries.append(.init(name: child.name!, isFolder: child.kind == Folder.kind))
        }
        return FolderManifest(entries: folderManifestEntries)
    }

    // Folder works outside the cache system and therefore cannot use "process". It is a Node with outputs, however.
    func refreshOutputs(thisNode: Node) throws {
        try thisNode.writeToOutputPort(Self.folderManifestOutputPort,
                                       value: .value(try buildManifest(thisNode: thisNode).toJSON().intern()))
    }
}
