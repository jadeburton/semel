//
//  FileSystem.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

struct FolderManifestEntry: Codable {
    let name: String
}

struct FolderManifest: PolySerializable {
    static let kind: UInt = 4

    let entries: [FolderManifestEntry]
}

final class FolderNode: NodeType {

    static let kind: UInt = 1

    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {
    }

    required init() {
    }

    required init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
    }

    static let folderManifestOutputPort = NodeKindDescriptor.OutputPort(index: 0, name: "folderManifest", kind: .value(dataType: .utf8Text))

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind,
              inputs: [],
              outputs: [Self.folderManifestOutputPort])
    }

    // when a child is added, we post a "child added" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    // when a child is deleted, we post a "child deleted" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    //
    func notifyChildAdded(nodeID: ObjectID, name: String) throws {
        try nodeContext.processingCycle.scheduleNode(nodeContext.nodeID!)
    }

    func notifyChildContentChanged(nodeID: ObjectID, name: String) throws {
        try nodeContext.processingCycle.scheduleNode(nodeContext.nodeID!)
    }

    @discardableResult
    func ensureEntirePathExists(_ path: String) throws -> FolderNode {
        // if input is a/b/c, we create a, if it does not already exist, then b, then c, and return the nodeID of c
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var currentFolder: FolderNode = self

        for name in components {
            if let existingChild: FolderNode = try currentFolder.child(named: name) {
                currentFolder = existingChild
            } else {
                let newFolder: FolderNode = try currentFolder.child(named: name, createIfNotExist: true)!
                try currentFolder.notifyChildAdded(nodeID: newFolder.nodeContext.nodeID!, name: name)
                currentFolder = newFolder
            }
        }

        return currentFolder
    }

    func addOrReplaceChild(content: DataObjectHash, name: String) throws {
        assert(!name.contains("\\"))

        let metadata = name

        if let existingChild = try nodeContext.processingCycle.node(named: name, parentNodeID: nodeContext.nodeID!) as StaticFileNode? {
            try existingChild.replaceContent(content, metadata: metadata)
            // TODO: only if changed
            try notifyChildContentChanged(nodeID: existingChild.nodeContext.nodeID!, name: existingChild.nodeContext.name!)
        } else {
            // TODO: what if the type is not StaticFileNode

            let staticFile = try nodeContext.processingCycle.makeNode(name: name, parentNodeID: nodeContext.nodeID!) as StaticFileNode
            try staticFile.replaceContent(content, metadata: metadata)

            try notifyChildAdded(nodeID: staticFile.nodeContext.nodeID!, name: staticFile.nodeContext.name!)
        }
    }

    private func buildManifest() throws -> FolderManifest {
        var folderManifestEntries = [FolderManifestEntry]()
        for child in try allChildren() {
            folderManifestEntries.append(.init(name: child.nodeContext.name!))
        }
        return FolderManifest(entries: folderManifestEntries)
    }

    func process() throws {
        try writeToOutputPort(Self.folderManifestOutputPort, value: .value(buildManifest().toJSON().intern(), metadata: nil) )
    }
}

struct FileMetadata: PolySerializable {
    static let kind: UInt = 14
    let name: String
}

final class FolderEvent: MessageType {
    enum FolderEventKind: Codable {
        case childAdded(nodeID: ObjectID, name: String)
        case childDeleted(nodeID: ObjectID, name: String)
        case childRenamed(nodeID: ObjectID, oldName: String, newName: String)
        case childMoved(nodeID: ObjectID, oldPath: String, newPath: String)
        case childContentChanged(nodeID: ObjectID, name: String)
    }

    static let kind: UInt = 100

    var folderEventKind: FolderEventKind?

    enum CodingKeys: CodingKey {
        case folderEventKind
    }

    required init() throws {
    }

    init(folderEventKind: FolderEventKind) {
        self.folderEventKind = folderEventKind
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folderEventKind = try container.decodeIfPresent(FolderEventKind.self, forKey: .folderEventKind)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(folderEventKind, forKey: .folderEventKind)
    }
}

