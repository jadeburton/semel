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

    func debugPrintTree() {
        // prints to the console an easy-to read dump of the build tree from right to left, e.g.

        // - build tree
        //   - StaticFile(mylib.dylib)
        //     - Linker
        //       - Compiler
        //         - Preprocessor
        //           - StaticFile(helpers.c)
        //           - StaticFile(helpers.h)
        //           - StaticFile(common.h)
        //         - Preprocessor
        //           - StaticFile(math.c)
        //           - StaticFile(math.h)
        //           - StaticFile(common.h)
        //       - LibraryRef(somelib.dylib)
        //   - StaticFile(someProgram)
        //     - Linker
        //       - Compiler
        //         - Preprocessor
        //           - StaticFile(main.c)
        //           - StaticFile(utility.h)
        //       - LibraryRef(somelib.dylib)

        // This does not simply direclty print the hierachy according to the parent-child relationship between Nodes.
        // (Nodes have both a parent-child relationship and relationships defined via Wires.)
        // Imagine a root node that has N children, which are the immediate children of the outputFileSystem node
        // then each of those children has N children, which are defined by what nodes they depend on (Nodes whose
        // outputs have Wires that go to any of their inputs), and so on recursively until we reach the leaf nodes
        // which have no dependencies (the input files.)
        // The graph's leaf Nodes may be shared by the graph's non-leaf Nodes, e.g. if two different .o files both
        // depend on common.h, then the Node representing common.h will be a child of both of the Nodes representing the .o files.

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

struct ToolDescriptor: Hashable {
    let name: String
    let version: String
    let platform: String
    let architecture: String
    let recursiveHash: String?
}

class ToolRegistry {
    private var toolsByDescriptor: [ToolDescriptor: Tool] = [:]

    func registerTool(descriptor: ToolDescriptor, tool: Tool) {
        toolsByDescriptor[descriptor] = tool
    }

    func tool(descriptor: ToolDescriptor) throws -> Tool? {
        toolsByDescriptor[descriptor]
    }
}

class DefaultTools {
    // TODO: in the future this would search the file system (or container's file system) for all known tools and register them,
    // but for now we will just hardcode clang as an example
    static func setup(toolRegistry: ToolRegistry) {
        try? toolRegistry.registerTool(descriptor: .init(name: "clang",
                                                         version: "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                                                         platform: "macOS",
                                                         architecture: "arm64",
                                                         recursiveHash: nil),
                                       tool: LocalFileSystemTool(localPath: "/bin/clang"))
    }
}

// A protocol that all build tools (compiler, linker, etc.) conform to, which allows the BuildGraph to treat them uniformly
// when integrating the build graph description and printing the dependency tree.
// Each Tool will have its own NodeKind and will be responsible for defining how it processes its inputs to produce outputs.
protocol Tool {
    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 output: ToolOutput) throws
}

protocol ToolOutput {
    func log(error: String)
    func log(message: String)
    func write(outputFilePath: String, data: [UInt8]) throws
    func didTerminate(exitCode: Int32)
}

struct FileNameAndContent {
    let fileName: String
    let content: [UInt8]
}

// Runs a tool that exists in the local file system, e.g. /usr/bin/clang
class LocalFileSystemTool: Tool {
    private let localPath: String

    init(localPath: String) throws {
        self.localPath = localPath
        // TODO: validate that the tool exists at the given path and is executable, and throw an error if not
    }

    func execute(arguments: [String],
                 environment: [String: String],
                 inputFiles: [FileNameAndContent],
                 expectedOutputFileNames: [String],
                 output: ToolOutput) throws {

        // Executes the tool at localPath with the given arguments.
        // Writes output files and logs via the ToolOutput protocol methods.
        // An important goal is to isolate the tool as much as possible. This means we must not pull in source files from the local file system;
        // all inputs must be explicitly passed in via the inputFiles, and all outputs must be explicitly written via the ToolOutput protocol methods.
        // The file names inside inputFiles are relative to the tool's execution context, and the tool should not be able to access any files outside of
        // those explicitly passed in. The same applies to output files.
        // This isolation is important to ensure that the build is hermetic and reproducible, and that it does not have unintended side effects on the local file system.
        // When a tool writes only to disk and does not support outputting to a pipe, we must use a temporary directory and let it write to that,
        // then read the temporary file ourselves afterwards. We must ensure that we clean up any temporary files after execution to avoid cluttering the local file system.
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
