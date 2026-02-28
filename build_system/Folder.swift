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

//    enum CodingKeys: String, CodingKey {
//        case dynamicOutputs
//    }

    required init() {
    }

    required init(from decoder: Decoder) throws {
//        let container = try decoder.container(keyedBy: CodingKeys.self)
//        dynamicOutputs = try container.decode([NodeKindDescriptor.OutputPort].self, forKey: .dynamicOutputs)
    }

    func encode(to encoder: Encoder) throws {
//        var container = encoder.container(keyedBy: CodingKeys.self)
//        try container.encode(dynamicOutputs, forKey: .dynamicOutputs)
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

    // Returns a named child (without path support)
    func child(named name: String) throws -> NodeType? {
        try nodeContext.childNode(named: name)
    }

    // Returns a child at a path (e.g. "src/main.swift"), this IS recursive.
    func child(path: String) -> NodeType? {
        nil
    }

    func addChild(_ node: NodeType) throws {
        node.nodeContext.parentNodeID = nodeContext.nodeID
        try nodeContext.buildEngine.saveNode(node)
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.OutputPort : NodeProcessPortOutput?] {
        [:]
    }
}
