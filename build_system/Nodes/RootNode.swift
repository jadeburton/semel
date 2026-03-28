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

    // MARK: Ports

    // Receives partial or complete schemas from multiple Nodes, merges them and synchronizes the actual Wires and Nodes with the schemas.
    // Note that all Nodes with a schemaOutput are automatically wired to RootNode.schemaInput when they are created.
    /*
     
    ClangCompiler rootNode/buildGraph/compiler(src/blah/hello.c)
     
    Wire rootNode/buildGraph/compiler(src/blah/hello.c) --> rootNode/buildGraph/inputFileSystem/src/blah/hello.c
     
     */
    
//    static let schemaInputPort = NodeKindDescriptor.InputPort(index: 0,
//                                                              name: "schemaInput",
//                                                              kind: .value(dataType: .utf8Text),
//                                                              maximumConnections: nil,
//                                                              minimumConnections: 0,
//                                                              cascadingDelete: false)

    /*

    Contains a full merged schema of all Wires and Nodes. There are no NodeIDs or WireIDs.

     */
//    static let schemaOutputPort = NodeKindDescriptor.OutputPort(index: 0,
//                                                                name: "schemaOutput",
//                                                                kind: .value(dataType: .utf8Text))
//
//    static let descriptor = NodeKindDescriptor(kind: kind, inputs: [schemaInputPort], outputs: [schemaOutputPort])

    func didSave() throws {
        try nodeContext.processingCycle.connectWire(fromNode: try inputFileSystem,
                                                    fromPort: FolderNode.folderManifestOutputPort,
                                                    toNode: try formulaFinder,
                                                    toPort: FormulaFinder.folderManifestInputPort)
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

//    var configurationFolder: FolderNode {
//        get throws {
//            try child(named: "configurationFolder", createIfNotExist: true)!
//        }
//    }

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [], outputs: [])
    }

    func process() throws {
    }
}
