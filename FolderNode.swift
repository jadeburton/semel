//
//  FileSystem.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

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

    static let childrenOutputPort = NodeKindDescriptor.OutputPort(index: 0, name: "children", kind: .messageStream(dataType: .utf8Text))
    static let logOutputPort = NodeKindDescriptor.OutputPort(index: 1, name: "log", kind: .messageStream(dataType: .utf8Text))
    static let hashOutputPort = NodeKindDescriptor.OutputPort(index: 2, name: "hash", kind: .value(dataType: .binary))

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind,
              inputs: [],
              outputs: [Self.childrenOutputPort, Self.logOutputPort, Self.hashOutputPort])
    }

    // when a child is added, we post a "child added" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    // when a child is deleted, we post a "child deleted" event to childrenOutputPort, then notify the parent folder, so it can also post the same event
    //
    func notifyChildAdded(nodeID: ObjectID, name: String) throws {

//        writeToOutputPortStream(Self.childrenOutputPort,
//                                data: "\(FolderEvent(folderEventKind: .childAdded(nodeID: nodeID, name: name)).toJSON())\n\n")

        let parent: FolderNode? = try parent()

        try parent?.notifyChildAdded(nodeID: nodeID,
                                     name: (self.nodeContext.name ?? "") + "/" + name)
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

        let metadata = FileMetadata(name: name)

        if let existingChild = try nodeContext.processingCycle.node(named: name, parentNodeID: nodeContext.nodeID!) as StaticFileNode? {
            try existingChild.writeToOutputPort(StaticFileNode.outputPort,
                                                value: .value(.dataObjectHash(content), metadata: metadata))
        } else {
            // TODO: what if the type is not StaticFileNode

            let staticFile = try nodeContext.processingCycle.makeNode(name: name, parentNodeID: nodeContext.nodeID!) as StaticFileNode
            try staticFile.replaceContent(content, metadata: metadata)

            try notifyChildAdded(nodeID: staticFile.nodeContext.nodeID!, name: staticFile.nodeContext.name!)
        }
    }

    func process() throws {
        try writeToOutputPort(Self.hashOutputPort, value: .noValue(reason: .error(message: "X")))
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

