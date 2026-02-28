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

    static let childrenOutputPort = NodeKindDescriptor.OutputPort(index: 0, name: "children", kind: .value(dataType: .utf8Text))
    static let logOutputPort = NodeKindDescriptor.OutputPort(index: 1, name: "log", kind: .value(dataType: .utf8Text))
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
        let dataObjectHash = [UInt8]("ADDED \(name):\(nodeID)".data(using: .utf8)!).intern()

        try nodeContext.processingCycle.postMutationEvent(nodeID: self.nodeContext.nodeID!,
                                                          outputPort: Self.childrenOutputPort.index,
                                                          dataObjectHash: dataObjectHash)

        let parent: FolderNode? = try parent()
        try parent?.notifyChildAdded(nodeID: nodeContext.nodeID!, name: (self.nodeContext.name ?? "") + "/" + name)
    }

    @discardableResult
    func ensureEntirePathExists(_ path: String) throws -> FolderNode {
        // if input is a/b/c, we create a, if it does not already exist, then b, then c, and return the nodeID of c
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        var currentFolder: FolderNode = self

        for name in components {
            if let existingChild: FolderNode = try currentFolder.childIfExists(named: name) {
                currentFolder = existingChild
            } else {
                let newFolder: FolderNode = try currentFolder.child(named: name)
                try currentFolder.notifyChildAdded(nodeID: newFolder.nodeContext.nodeID!, name: name)
                currentFolder = newFolder
            }
        }

        return currentFolder
    }

    func addOrReplaceChild(content: DataObjectHash, name: String) throws {
        assert(!name.contains("\\"))

        if let existingChild = try nodeContext.processingCycle.node(named: name, parentNodeID: nodeContext.nodeID!) as StaticFileNode? {
            try existingChild.assignValue(outputPort: StaticFileNode.outputPort, value: .value(content))
        } else {
            // TODO: what if the type is not StaticFileNode
            let staticFile = StaticFileNode()
            staticFile.nodeContext = .init(processingCycle: nodeContext.processingCycle, parentNodeID: nodeContext.nodeID, name: name)
            staticFile.nodeContext.nodeID = try nodeContext.processingCycle.saveNode(staticFile)
            try staticFile.assignValue(outputPort: StaticFileNode.outputPort, value: .value(content))
            try notifyChildAdded(nodeID: staticFile.nodeContext.nodeID!, name: staticFile.nodeContext.name!)
        }
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.OutputPort : NodeProcessPortOutput?] {
        [:]
    }
}
