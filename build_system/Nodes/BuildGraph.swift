//
//  BuildGraph.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

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

    func debugPrintTree() {
        // prints to the console an easy-to read dump of the build tree from right to left

        do {
            let outputFolder = try outputFileSystem
            let topLevelOutputNodes = try nodeContext.processingCycle.allChildNodes(nodeID: outputFolder.nodeContext.nodeID!)

            print("- build tree")

            for outputNode in topLevelOutputNodes {
                printDependencyTree(node: outputNode, indentLevel: 1)
            }
        } catch {
            print("- build tree (error: \(error))")
        }
    }

    private func printDependencyTree(node: NodeType, indentLevel: Int) {
        let indent = String(repeating: "  ", count: indentLevel)
        let kindName = (try? PolyFactory.type(kind: node.descriptor.kind))
            .map { String(describing: $0) } ?? "Node"
        let nodeName = node.nodeContext.name ?? "?"
        print("\(indent)- \(kindName)(\(nodeName))")

        // Find all nodes that this node depends on by looking at its input wires.
        // Each input wire's fromNodeID is a dependency.
        let database = nodeContext.processingCycle.database
        guard let nodeID = node.nodeContext.nodeID else { return }

        do {
            let incomingWires = try database.selectWires(goingToNodeID: nodeID)

            // Deduplicate dependencies: a node may be wired to multiple input ports,
            // but we only want to print it once at this level.
            var visitedDependencyNodeIDs = Set<ObjectID>()
            var dependencyNodes = [NodeType]()

            for wire in incomingWires {
                guard !visitedDependencyNodeIDs.contains(wire.fromNodeID) else { continue }
                visitedDependencyNodeIDs.insert(wire.fromNodeID)

                if let rawNode = try? database.selectNodeByID(wire.fromNodeID) {
                    if let dependencyNode = try? nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: rawNode) {
                        dependencyNodes.append(dependencyNode)
                    }
                }
            }

            for dependencyNode in dependencyNodes {
                printDependencyTree(node: dependencyNode, indentLevel: indentLevel + 1)
            }
        } catch {
            print("\(indent)  (error loading dependencies: \(error))")
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

                case .value(let dataObjectHash, let metadata):
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

protocol Tool: PolySerializable {
    func processInputs(node: ToolNode, inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws
}

class ClangCompilerTool: Tool {

    let toolDescriptor: ToolDescriptor!
    let arguments: [String]
    let environment: [String: String]

    required init() throws {
        toolDescriptor = nil
        arguments = []
        environment = [:]
    }

    static let kind: UInt = 10

    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {
        case toolDescriptor
        case arguments
        case environment
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toolDescriptor = try container.decode(ToolDescriptor.self, forKey: .toolDescriptor)
        self.arguments = try container.decode([String].self, forKey: .arguments)
        self.environment = try container.decode([String: String].self, forKey: .environment)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolDescriptor, forKey: .toolDescriptor)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
    }

    func processInputs(node: ToolNode, inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws {

        guard let firstInputValue = try node.readFromInputPort(ToolNode.input).first else {
            return
        }

        switch firstInputValue {

            case .noValue:
                try node.writeToOutputPort(ToolNode.output, value: .noValue(reason: .awaitingDependency))
                return

            case .value(let dataObjectHash, let metadata):

                let bytes = dataObjectHash.resolve()!

                var output: [UInt8] = []

                var arguments = [String]()

                arguments.append("-x")
                arguments.append("cpp-output")
                arguments.append("-c")
                arguments.append("source.pc")
                arguments.append("-o")
                arguments.append("source.o")
                arguments.append("-target")
                arguments.append("arm64-apple-macos14.0")

                arguments.append(contentsOf: self.arguments)

                guard let tool = try ToolExecutorRegistry.instance.tool(descriptor: toolDescriptor) else {
                    return
                }

                let exitCode = try tool.execute(arguments: arguments,
                                                environment: environment,
                                                inputFiles: [.init(fileName: "source.pc", content: bytes)],
                                                expectedOutputFileNames: ["source.o"],
                                                output: .init(logError: { error in },
                                                              logMessage: { message in },
                                                              write: { filePath, data in output.append(contentsOf: data) }))

                if exitCode == 0 {
                    try node.writeToOutputPort(ToolNode.output, value: .value(output.intern(), "source.o"))
                } else {
                    try node.writeToOutputPort(ToolNode.output, value: .noValue(reason: .error(stack: [])))
                }
        }
    }
}

class ClangPreprocessorTool: Tool {

    let toolDescriptor: ToolDescriptor!
    let arguments: [String]
    let environment: [String: String]

    required init() throws {
        toolDescriptor = nil
        arguments = []
        environment = [:]
    }

    static let kind: UInt = 11

    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {
        case toolDescriptor
        case arguments
        case environment
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toolDescriptor = try container.decode(ToolDescriptor.self, forKey: .toolDescriptor)
        self.arguments = try container.decode([String].self, forKey: .arguments)
        self.environment = try container.decode([String: String].self, forKey: .environment)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolDescriptor, forKey: .toolDescriptor)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
    }

    func processInputs(node: ToolNode, inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws {

        let inputValues = try node.readFromInputPort(ToolNode.input)

        guard let primarySourceFile = inputValues.first(where: { nodeOutputValue in

            switch nodeOutputValue {
            case .value(let dataObjectHash, let metadata):
                return metadata?.hasSuffix(".c") ?? false
            default:
                return false
            }

        }) else {
            return
        }

        var headerFiles: [FileNameAndContent] = inputValues.filter { nodeOutputValue in
            switch nodeOutputValue {
            case .value(let dataObjectHash, let metadata):
                return metadata?.hasSuffix(".h") ?? false
            default:
                return false
            }
        }.compactMap { nodeOutputValue in
            switch nodeOutputValue {
            case .value(let dataObjectHash, let metadata):
                return FileNameAndContent(fileName: metadata!, content: dataObjectHash.resolve()!)
            case .noValue:
                return nil
            }
        }

        switch primarySourceFile {

            case .noValue:
                try node.writeToOutputPort(ToolNode.output, value: .noValue(reason: .awaitingDependency))
                return

            case .value(let dataObjectHash, let metadata):

                let bytes = dataObjectHash.resolve()!

                var output: [UInt8] = []

                var arguments = [String]()

                arguments.append("-x")// TODO
                arguments.append("cpp-output")
                arguments.append("-c")
                arguments.append("source.pc")
                arguments.append("-o")
                arguments.append("source.o")
                arguments.append("-target")
                arguments.append("arm64-apple-macos14.0")

                arguments.append(contentsOf: self.arguments)

                guard let tool = try ToolExecutorRegistry.instance.tool(descriptor: toolDescriptor) else {
                    return
                }

                var inputFiles: [FileNameAndContent] = [.init(fileName: "source.c", content: bytes)]
                inputFiles.append(contentsOf: headerFiles)

                let exitCode = try tool.execute(arguments: arguments,
                                                environment: environment,
                                                inputFiles: inputFiles,
                                                expectedOutputFileNames: ["source.pc"],
                                                output: .init(logError: { error in },
                                                              logMessage: { message in },
                                                              write: { filePath, data in output.append(contentsOf: data) }))

                if exitCode == 0 {
                    try node.writeToOutputPort(ToolNode.output, value: .value(output.intern(), "source.pc"))
                } else {
                    try node.writeToOutputPort(ToolNode.output, value: .noValue(reason: .error(stack: [])))
                }
        }
    }
}

class ClangLinkerTool: Tool {

    let toolDescriptor: ToolDescriptor!
    let arguments: [String]
    let environment: [String: String]

    required init() throws {
        toolDescriptor = nil
        arguments = []
        environment = [:]
    }

    static let kind: UInt = 12

    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {
        case toolDescriptor
        case arguments
        case environment
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toolDescriptor = try container.decode(ToolDescriptor.self, forKey: .toolDescriptor)
        self.arguments = try container.decode([String].self, forKey: .arguments)
        self.environment = try container.decode([String: String].self, forKey: .environment)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolDescriptor, forKey: .toolDescriptor)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
    }

    func processInputs(node: ToolNode, inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws {

        let inputValues = try node.readFromInputPort(ToolNode.input)

        var libraryFiles: [FileNameAndContent] = inputValues.filter { nodeOutputValue in
            switch nodeOutputValue {
            case .value(let dataObjectHash, let metadata):
                return metadata?.hasSuffix(".dylib") ?? false
            default:
                return false
            }
        }.compactMap { nodeOutputValue in
            switch nodeOutputValue {
            case .value(let dataObjectHash, let metadata):
                return FileNameAndContent(fileName: metadata!, content: dataObjectHash.resolve()!)
            case .noValue:
                return nil
            }
        }

        var objectFiles: [FileNameAndContent] = inputValues.filter { nodeOutputValue in
            switch nodeOutputValue {
            case .value(let dataObjectHash, let metadata):
                return metadata?.hasSuffix(".o") ?? false
            default:
                return false
            }
        }.compactMap { nodeOutputValue in
            switch nodeOutputValue {
            case .value(let dataObjectHash, let metadata):
                return FileNameAndContent(fileName: metadata!, content: dataObjectHash.resolve()!)
            case .noValue:
                return nil
            }
        }

 //       let bytes = dataObjectHash.resolve()!

        var output: [UInt8] = []

        var arguments = [String]()

        arguments.append("-x")// TODO
        arguments.append("cpp-output")
        arguments.append("-c")
        arguments.append("source.pc")
        arguments.append("-o")
        arguments.append("source.o")
        arguments.append("-target")
        arguments.append("arm64-apple-macos14.0")

        arguments.append(contentsOf: self.arguments)

        guard let tool = try ToolExecutorRegistry.instance.tool(descriptor: toolDescriptor) else {
            return
        }

        var inputFiles: [FileNameAndContent] = []
        inputFiles.append(contentsOf: libraryFiles)
        inputFiles.append(contentsOf: objectFiles)

        let exitCode = try tool.execute(arguments: arguments,
                                        environment: environment,
                                        inputFiles: inputFiles,
                                        expectedOutputFileNames: ["source.dylib"],
                                        output: .init(logError: { error in },
                                                      logMessage: { message in },
                                                      write: { filePath, data in output.append(contentsOf: data) }))

        if exitCode == 0 {
            try node.writeToOutputPort(ToolNode.output, value: .value(output.intern(), "source.dylib"))
        } else {
            try node.writeToOutputPort(ToolNode.output, value: .noValue(reason: .error(stack: [])))
        }
    }
}


class ToolNode: NodeType {

    required init() throws {
    }

    static let kind: UInt = 9

    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {
    }

    required init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
    }

    static let input = NodeKindDescriptor.InputPort(index: 0,
                                                    name: "input",
                                                    kind: .value(dataType: .binary),
                                                    maximumConnections: nil,
                                                    minimumConnections: 1)

    static let configuration = NodeKindDescriptor.InputPort(index: 1,
                                                            name: "configuration",
                                                            kind: .value(dataType: .utf8Text),
                                                            maximumConnections: 1,
                                                            minimumConnections: 1)

    static let output = NodeKindDescriptor.OutputPort(index: 0,
                                                      name: "output",
                                                      kind: .value(dataType: .binary))

    static let errorLog = NodeKindDescriptor.OutputPort(index: 1,
                                                        name: "errorLog",
                                                        kind: .value(dataType: .utf8Text))

    static let infoLog = NodeKindDescriptor.OutputPort(index: 2,
                                                       name: "infoLog",
                                                       kind: .value(dataType: .utf8Text))

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind,
              inputs: [Self.input,
                       Self.configuration],
              outputs: [Self.output,
                        Self.errorLog,
                        Self.infoLog])
    }

    private func makeTool() throws -> Tool? {

        guard let configurationValue = try readFromInputPort(Self.configuration).first else {
            return nil
        }

        switch configurationValue {

        case .noValue:
            return nil

        case .value(let dataObjectHash, let metadata):

            guard let data = dataObjectHash.resolve() else {
                return nil
            }

            let configurationString = String(decoding: data, as: Unicode.UTF8.self)
            return try PolyFactory.make(encodedJSON: configurationString) as! Tool?
        }
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeInputMessage]?]) throws {

        guard let tool = try makeTool() else {
            try writeToOutputPort(Self.output, value: .noValue(reason: .awaitingDependency))
            return
        }

        try tool.processInputs(node: self, inputs: inputs)
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

                case .value(let dataObjectHash, let metadata):
                    // This extractor just passes through
                    try writeToOutputPort(Self.formulaOutputPort, value: .value(dataObjectHash, metadata))

                }

            case .error:
                break

            case .wireDisconnected:
                print("wire disconnected")

            }
        }
    }
}

struct ToolDescriptor: Hashable, Codable {
    let name: String
    let version: String
    let platform: String
    let architecture: String
    let recursiveHash: String?
}

class ToolExecutorRegistry {
    static let instance = ToolExecutorRegistry()

    private var toolsByDescriptor: [ToolDescriptor: ToolExecutor] = [:]

    func registerTool(descriptor: ToolDescriptor, toolExecutor: ToolExecutor) {
        toolsByDescriptor[descriptor] = toolExecutor
    }

    func tool(descriptor: ToolDescriptor) throws -> ToolExecutor? {
        toolsByDescriptor[descriptor]
    }
}

class DefaultTools {
    // TODO: in the future this would search the file system (or container's file system) for all known tools and register them,
    // but for now we will just hardcode clang as an example
    static func setup(toolExecutorRegistry: ToolExecutorRegistry) {
        try? toolExecutorRegistry.registerTool(descriptor: .init(name: "clang",
                                                                 version: "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                                                                 platform: "macOS",
                                                                 architecture: "arm64",
                                                                 recursiveHash: nil),
                                               toolExecutor: LocalFileSystemTool(localPath: "/bin/clang"))
    }
}

// A protocol that all build tools (compiler, linker, etc.) conform to, which allows the BuildGraph to treat them uniformly
// when integrating the build graph description and printing the dependency tree.
// Each Tool will have its own NodeKind and will be responsible for defining how it processes its inputs to produce outputs.
protocol ToolExecutor {
    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 output: ToolOutput) throws -> Int32
}

struct ToolOutput {
    let logError: (_ error: String) -> Void
    let logMessage: (_ message: String) -> Void
    let write: (_ filePath: String, _ data: [UInt8]) -> Void
}

struct FileNameAndContent {
    let fileName: String
    let content: [UInt8]
}

enum ToolExecutionError: Error {
    case toolNotFound(path: String)
    case toolNotExecutable(path: String)
    case failedToCreateSandbox(underlying: Error)
    case failedToWriteInputFile(fileName: String, underlying: Error)
    case failedToReadOutputFile(fileName: String)
    case processLaunchFailed(underlying: Error)
}

// Runs a tool that exists in the local file system, e.g. /usr/bin/clang
class LocalFileSystemTool: ToolExecutor {
    private let localPath: String

    init(localPath: String) throws {
        self.localPath = localPath

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: localPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ToolExecutionError.toolNotFound(path: localPath)
        }
        guard fileManager.isExecutableFile(atPath: localPath) else {
            throw ToolExecutionError.toolNotExecutable(path: localPath)
        }
    }

    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 output: ToolOutput) throws -> Int32 {

        // Executes the tool at localPath with the given arguments.
        // Writes output files and logs via the ToolOutput protocol methods.
        // An important goal is to isolate the tool as much as possible. This means we must not pull in source files from the local file system;
        // all inputs must be explicitly passed in via the inputFiles, and all outputs must be explicitly written via the ToolOutput protocol methods.
        // The file names inside inputFiles are relative to the tool's execution context, and the tool should not be able to access any files outside of
        // those explicitly passed in. The same applies to output files.
        // This isolation is important to ensure that the build is hermetic and reproducible, and that it does not have unintended side effects on the local file system.
        // When a tool writes only to disk and does not support outputting to a pipe, we must use a temporary directory and let it write to that,
        // then read the temporary file ourselves afterwards. We must ensure that we clean up any temporary files after execution to avoid cluttering the local file system.

        let fileManager = FileManager.default

        // 1. Create a temporary sandbox directory.
        //    All input files will be written here, and the tool's working directory will be set to this path.
        //    This ensures the tool cannot access files outside the sandbox.

        let sandboxPath: String
        do {
            let sandboxURL = try fileManager.url(for: .itemReplacementDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: fileManager.temporaryDirectory,
                                                 create: true)
            sandboxPath = sandboxURL.path
        } catch {
            throw ToolExecutionError.failedToCreateSandbox(underlying: error)
        }

        // Ensure the sandbox is always cleaned up, even if we throw partway through.
        defer {
            try? fileManager.removeItem(atPath: sandboxPath)
        }

        // 2. Write all input files into the sandbox.
        //    Intermediate directories are created as needed so that relative paths like "src/main.c" work.

        for inputFile in inputFiles {
            let inputFileURL = Foundation.URL(fileURLWithPath: sandboxPath).appendingPathComponent(inputFile.fileName)
            let containingDirectory = inputFileURL.deletingLastPathComponent().path

            do {
                if !fileManager.fileExists(atPath: containingDirectory) {
                    try fileManager.createDirectory(atPath: containingDirectory, withIntermediateDirectories: true)
                }
                try Foundation.Data(inputFile.content).write(to: inputFileURL)
            } catch {
                throw ToolExecutionError.failedToWriteInputFile(fileName: inputFile.fileName, underlying: error)
            }
        }

        // 3. Configure and launch the process.

        let process = Foundation.Process()
        process.executableURL = Foundation.URL(fileURLWithPath: localPath)
        process.arguments = arguments
        process.currentDirectoryURL = Foundation.URL(fileURLWithPath: sandboxPath)

        // Merge the caller-supplied environment on top of a minimal base environment.
        // We intentionally do NOT inherit the host's full environment to maintain hermeticity.
        var processEnvironment = [String: String]()
        processEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        processEnvironment["HOME"] = sandboxPath
        processEnvironment["TMPDIR"] = sandboxPath
        for (key, value) in environment {
            processEnvironment[key] = value
        }
        process.environment = processEnvironment

        let stdoutPipe = Foundation.Pipe()
        let stderrPipe = Foundation.Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ToolExecutionError.processLaunchFailed(underlying: error)
        }

        // 4. Wait for the process to finish and collect stdout/stderr.

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let exitCode = process.terminationStatus

        // 5. Forward stdout and stderr to the ToolOutput as log messages.

        if let stdoutString = String(data: stdoutData, encoding: .utf8), !stdoutString.isEmpty {
            output.logMessage(stdoutString)
        }

        if let stderrString = String(data: stderrData, encoding: .utf8), !stderrString.isEmpty {
            output.logError(stderrString)
        }

        // 6. Read back each expected output file from the sandbox and write it via ToolOutput.
        //    If an expected output file is missing (e.g. because the tool failed), log an error but continue
        //    reading other outputs so the caller gets as much information as possible.

        for expectedOutputFileName in expectedOutputFileNames {
            let outputFileURL = Foundation.URL(fileURLWithPath: sandboxPath).appendingPathComponent(expectedOutputFileName)

            if let outputFileData = fileManager.contents(atPath: outputFileURL.path) {
                output.write(expectedOutputFileName, [UInt8](outputFileData))
            } else {
                output.logError("Expected output file not found: \(expectedOutputFileName)")
            }
        }

        return exitCode

        // The defer block above will clean up the sandbox directory.
    }
}
/*
class DockerContainerHost {
    let hostAddress: String

    init(hostAddress: String) {
        self.hostAddress = hostAddress
    }

    // If containerName is provided, it should be used to identify an existing container to use for executing the tool.
    // If containerName is not provided, a new container should be spun up for executing the tool
    func container(imageName: String, containerName: String?) throws -> DockerContainer {
        // TODO
        .init()
    }
}

class DockerContainer {
//    let imageName: String
//    let containerName: String
}

class DockerContainerizedTool: Tool {

    // The remote or local Docker container to use for executing this tool, internally this has a name e.g. "clang-15-container".
    // Ideally the container would be created and destroyed for every execution. However as this would be too slow,
    // one container can receive multiple commands. Care should be taken to try to keep the state of the container
    // clean by deleting temporary or output files after each execution, but this is not guaranteed to be perfectly clean.
    // TODO: maybe a checkpoint and rollback is possible?
    // In general we should also avoid executing multiple commands in parallel in the same container to avoid conflicts,
    // but this is not strictly required as long as we can ensure that the commands do not step on each other's files.
    private let dockerContainer: DockerContainer

    // The path of the tool inside the docker container, e.g. /usr/bin/clang
    private let toolPath: String

    init(dockerContainer: DockerContainer, toolPath: String) {
        self.dockerContainer = dockerContainer
        self.toolPath = toolPath
    }


    func execute(arguments: [String], inputFiles: [FileNameAndContent], expectedOutputFileNames: [String], output: ToolOutput) throws {
        // Connects to a remote Docker container host, spins up a container that contains the desired tool and runs the
        // tool with arguments, then pulls the output files from the container.
    }
}
*/
