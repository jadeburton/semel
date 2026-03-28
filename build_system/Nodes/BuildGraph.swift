//
//  BuildGraph.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

final class ClangCCompiler {
//    func compile(inputFiles: [String], )
}

struct BuildGraphInputWire {
    let from: BuildGraphNode
    let fromPort: String
}

struct BuildGraphInputPort {
    let name: String
    let inputWires: [BuildGraphInputWire]
}

struct BuildGraphDescription {
    let outputs: [BuildGraphNode]
}

final class BuildGraphNode {
    let name: String
    let kind: UInt

    let inputPorts: [BuildGraphInputPort]

    init(name: String, kind: UInt, inputPorts: [BuildGraphInputPort]) {
        self.name = name
        self.kind = kind
        self.inputPorts = inputPorts
    }
}

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

    func integrateFormula(formula: String) throws {
        print("integrate formula: \(formula)")

        let inputWiresForLinker = [BuildGraphInputWire(from: .init(name: "compiler-blah-c",
                                                                  kind: StaticFileNode.kind, // TODO
                                                                  inputPorts: [.init(name: "input",
                                                                                     inputWires: [
                                                                                    .init(from: .init(name: "Nodes/BuildGraph.swift", kind: StaticFileNode.kind, inputPorts: []),
                                                                                          fromPort: "output")
                                                                           ])]),
                                                    fromPort: "output")]


        let inputWiresForStaticFile = [BuildGraphInputWire(from: .init(name: "linker-mylib",
                                                                      kind: StaticFileNode.kind,
                                                                      inputPorts: [.init(name: "input",
                                                                                         inputWires: inputWiresForLinker)]),
                                                          fromPort: "output")]


        let buildGraphDescription = BuildGraphDescription(
            outputs: [
                .init(name: "mylib.dylib",
                      kind: StaticFileNode.kind,
                      inputPorts: [.init(name: "input", inputWires: inputWiresForStaticFile)])])

        try integrateBuildGraphDescription(buildGraphDescription)
    }

    var outputFileSystem: FolderNode {
        get throws {
            try child(named: "outputFileSystem", createIfNotExist: true)!
        }
    }

    private func integrateBuildGraphDescription(_ buildGraphDescription: BuildGraphDescription) throws {
        for output in buildGraphDescription.outputs {
            try integrate(buildGraphOutput: output)
        }
    }

    private func integrate(buildGraphOutput: BuildGraphNode) throws {
        try integrate(buildGraphNode: buildGraphOutput,
                      currentNode: try outputFileSystem.child(path: buildGraphOutput.name, createIfNotExist: true)! as StaticFileNode)
    }

    private func integrate(buildGraphNode: BuildGraphNode, currentNode: NodeType) throws {

        for inputPort in buildGraphNode.inputPorts {
            for inputWire in inputPort.inputWires {

                var nodeConnectedToInputWire = try currentNode.findNodeConnectedToNodeViaInputWire(named: inputWire.from.name,
                                                                                                   fromPort: inputWire.fromPort)

                if nodeConnectedToInputWire == nil {
                    // The Wire or Node we want does not exist.

                    let isInputLeafNode = inputWire.from.inputPorts.isEmpty

                    if isInputLeafNode {
                        // IF it is a left side input file, we need to look in the input file system to locate the file and not create it if we don't find it
                        let inputFileNode = try nodeContext.processingCycle.rootNode.inputFileSystem.childPoly(path: inputWire.from.name, kind: StaticFileNode.kind)
                        nodeConnectedToInputWire = inputFileNode
                    } else {
                        nodeConnectedToInputWire = try childPoly(named: inputWire.from.name, kind: inputWire.from.kind, createIfNotExist: true)!
                    }
                }

                try nodeContext.processingCycle.connectWire(fromNode: nodeConnectedToInputWire!,
                                                            fromPort: nodeConnectedToInputWire!.descriptor.outputPort(named: inputWire.fromPort)!,
                                                            toNode: currentNode,
                                                            toPort: currentNode.descriptor.inputPort(named: inputPort.name)!)

                // Move leftwards to the next Node
                try integrate(buildGraphNode: inputWire.from, currentNode: nodeConnectedToInputWire!)
            }
        }
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws {
        let inputMessages = inputs[Self.formulaeInputPort]! ?? []

        for formulaFileMessage in inputMessages {
            switch formulaFileMessage.kind {

            case .valueMutated, .wireConnected:

                switch formulaFileMessage.originOutputPortValue {

                case .noValue:
                    break

                case .value(let dataObjectHash):
                    let bytes = dataObjectHash.resolve()!
                    let string = String(decoding: bytes, as: Unicode.UTF8.self)

                    try integrateFormula(formula: string)
                }

            case .error:
                break

            case .wireDisconnected:
                print("wire disconnected")

            }
        }
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

    func didAddFile(nodeID: ObjectID, name: String) throws {
        // if the file is a .formula file:
        // 1. create a FormulaExtractor as a child of self
        // 2. Wire the formula file value to the FE's input
        // 3. Wire the FE's filelist input to the parent directory of the formula, so it can monitor files
        // 4. Wire the FE's formula output to the BuildGraph's formula input

        // when the formula file is deleted and its wires deleted, the FE will self-delete

        guard name.hasSuffix(".yml") else {
            return
        }

        let extractor = try nodeContext.processingCycle.makeNode(name: name, parentNodeID: nodeContext.nodeID) as FormulaExtractor

        try nodeContext.processingCycle.connectWire(fromNode: try nodeContext.processingCycle.node(nodeID: nodeID) as StaticFileNode,
                                                    fromPort: StaticFileNode.outputPort,
                                                    toNode: extractor,
                                                    toPort: FormulaExtractor.formulaFileInputPort)

        try nodeContext.processingCycle.connectWire(fromNode: extractor,
                                                    fromPort: FormulaExtractor.formulaOutputPort,
                                                    toNode: try nodeContext.processingCycle.rootNode.buildGraph,
                                                    toPort: BuildGraph.formulaeInputPort)
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws {
        let inputMessages = inputs[Self.fileListInputPort]! ?? []

        for fileListMessage in inputMessages {
            switch fileListMessage.kind {

            case .valueMutated(let delta):
                if let delta {
                    let bytes = delta.resolve()!
                    let string = String(decoding: bytes, as: Unicode.UTF8.self)
                    let message = try PolyFactory.make(encodedJSON: string)

                    if let cast = message as? FolderEvent {
                        if let folderEventKind = cast.folderEventKind {
                            print("folder event: \(folderEventKind)")

                            switch folderEventKind {
                            case .childAdded(let nodeID, let name):
                                try didAddFile(nodeID: nodeID, name: name)

                            default:
                                break
                            }
                        }
                    }

                }
                break

            case .error:
                break

            case .wireConnected:
                print("wire connected")

            case .wireDisconnected:
                print("wire disconnected")

            }

            // add file/folder
            // remove file/folder
            // filter, if a .formula file then wire up to listen for mutations
            // if deleted, remove the wires (should be already?)
            //
        }
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

    static let formulaFileInputPort = NodeKindDescriptor.InputPort(index: 0,
                                                                   name: "formulaFile",
                                                                   kind: .value(dataType: .utf8Text),
                                                                   maximumConnections: 1,
                                                                   minimumConnections: 1)

    static let formulaOutputPort = NodeKindDescriptor.OutputPort(index: 0,
                                                                 name: "formula",
                                                                 kind: .value(dataType: .utf8Text))

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [Self.formulaFileInputPort], outputs: [Self.formulaOutputPort])
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws {
        let inputMessages = inputs[Self.formulaFileInputPort]! ?? []

        for formulaFileMessage in inputMessages {
            switch formulaFileMessage.kind {

            case .valueMutated, .wireConnected:

                switch formulaFileMessage.originOutputPortValue {

                case .noValue:
                    break

                case .value(let dataObjectHash):
                    // This extractor just passes through
                    try writeToOutputPort(Self.formulaOutputPort, value: .value(dataObjectHash))

                }

            case .error:
                break

            case .wireDisconnected:
                print("wire disconnected")

            }
        }
    }
}
