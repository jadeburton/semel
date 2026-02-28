//
//  FileSystem.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

final class Folder: NodeType {

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

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind,
              inputs: [],
              outputs: [
                  .init(index: 0, name: "children", kind: .value(dataType: .binary)), // a list of Node descriptors (ID, kind) and names. This is not recursive.
                  .init(index: 1, name: "log", kind: .value(dataType: .utf8Text)),
                  .init(index: 2, name: "hash", kind: .value(dataType: .binary)) // a hash of the contents of the folder, which can be used for caching. This IS recursive.
              ])
    }

    func addOrReplaceChild(content: DataObjectHash, name: String) throws {
        if let existingChild = try nodeContext.processingCycle.node(named: name, parentNodeID: nodeContext.nodeID!) as StaticFileNode? {
            try existingChild.assignValue(outputPort: StaticFileNode.outputPort, value: .value(content))
        } else {
            // TODO: what if the type is not StaticFileNode
            let staticFile = StaticFileNode()
            staticFile.nodeContext = .init(processingCycle: nodeContext.processingCycle, parentNodeID: nodeContext.nodeID, name: name)
            staticFile.nodeContext.nodeID = try nodeContext.processingCycle.saveNode(staticFile)
            try staticFile.assignValue(outputPort: StaticFileNode.outputPort, value: .value(content))
        }
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.OutputPort : NodeProcessPortOutput?] {
        [:]
    }
}
