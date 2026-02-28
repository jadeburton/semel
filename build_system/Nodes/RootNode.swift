//
//  RootNode.swift
//  build_system
//
//  Created by Jade Burton on 28.02.26.
//

import Foundation

final class RootNode: NodeType {

    static let kind: UInt = 10

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

    var commandInterpreter: CommandInterpreter {
        get throws {
            try child(named: "commandInterpreter")
        }
    }

    var inputFileSystem: Folder {
        get throws {
            try child(named: "inputFileSystem")
        }
    }

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [], outputs: [])
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws -> [NodeKindDescriptor.OutputPort : NodeProcessPortOutput?] {
        [:]
    }
}
