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

    func didSave() throws {
        try nodeContext.processingCycle.connectWire(fromNode: try inputFileSystem,
                                                    fromPort: FolderNode.childrenOutputPort,
                                                    toNode: try formulaFinder,
                                                    toPort: FormulaFinder.fileListInputPort)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
    }

    var commandInterpreter: CommandInterpreter {
        get throws {
            try child(named: "commandInterpreter", createIfNotExist: true)!
        }
    }

    var inputFileSystem: FolderNode {
        get throws {
            try child(named: "inputFileSystem", createIfNotExist: true)!
        }
    }

    var formulaFinder: FormulaFinder {
        get throws {
            try child(named: "formulaFinder", createIfNotExist: true)!
        }
    }

    var buildGraph: BuildGraph {
        get throws {
            try child(named: "buildGraph", createIfNotExist: true)!
        }
    }

    var configurationFolder: FolderNode {
        get throws {
            try child(named: "configurationFolder", createIfNotExist: true)!
        }
    }

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [], outputs: [])
    }

    func process() throws {
    }
}
