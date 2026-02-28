//
//  BuildGraph.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

final class BuildGraph: NodeType {
    static let kind: UInt = 2

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

    static let formulaeInputPort = NodeKindDescriptor.InputPort(index: 0,
                                                                name: "formulae",
                                                                kind: .value(dataType: .utf8Text),
                                                                maximumConnections: nil,
                                                                minimumConnections: 0)

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [Self.formulaeInputPort], outputs: [])
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws {
    }
}


// A factory and container for FormulaExtractor nodes, which will extract formulae from the project files and feed them into the BuildGraph.
final class FormulaFinder: NodeType {
    static let kind: UInt = 5

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

    static let fileListInputPort = NodeKindDescriptor.InputPort(index: 0,
                                                                name: "fileList",
                                                                kind: .value(dataType: .utf8Text),
                                                                maximumConnections: 1,
                                                                minimumConnections: 1)

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [Self.fileListInputPort], outputs: [])
    }

    func didAddFile(_ path: String) {
        // if the file is a .formula file:
        // 1. create a FormulaExtractor as a child of self
        // 2. Wire the formula file value to the FE's input
        // 3. Wire the FE's filelist input to the parent directory of the formula, so it can monitor files
        // 4. Wire the FE's formula output to the BuildGraph's formula input

        // when the formula file is deleted and its wires deleted, the FE will self-delete
        
        
        
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws {
//        let inputMessages = inputs[Self.fileListInputPort]! ?? []

//        for fileListMessage in inputMessages {
//            let originNodeID: ObjectID
//            let originOutputPort: UInt8
//            let kind: NodeInputMessageKind

            // add file/folder
            // remove file/folder
            // filter, if a .formula file then wire up to listen for mutations
            // if deleted, remove the wires (should be already?)
            //
//        }
    }
}



// Connects to a .formula file in the file system. Also monitors the parent directory for add/remove of files referenced by the formula.
final class FormulaExtractor: NodeType {
    static let kind: UInt = 6

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

    static let fileListInputPort = NodeKindDescriptor.InputPort(index: 0,
                                                                name: "fileList",
                                                                kind: .value(dataType: .utf8Text),
                                                                maximumConnections: 1,
                                                                minimumConnections: 1)

    static let formulaeOutputPort = NodeKindDescriptor.OutputPort(index: 0,
                                                                  name: "formulae",
                                                                  kind: .value(dataType: .utf8Text))

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [Self.fileListInputPort], outputs: [Self.formulaeOutputPort])
    }

    func didAddFile(_ path: String) {
        // if it is a .c file, we need to find the corresponding project file and update the formula.
        
    }

    func didRemoveFile(_ path: String) {
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws {
        //let inputMessages = inputs[Self.fileListInputPort]! ?? []

        //for fileListMessage in inputMessages {
//            let originNodeID: ObjectID
//            let originOutputPort: UInt8
//            let kind: NodeInputMessageKind

            // add file/folder
            // remove file/folder
            // filter, if a .formula file then wire up to listen for mutations
            // if deleted, remove the wires (should be already?)
            //
        //}
    }
}
