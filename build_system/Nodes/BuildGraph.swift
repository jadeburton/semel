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

struct BuildGraphNode {
    let name: String
    let kind: BuildGraphNodeKind
}

enum BuildGraphNodeKind {
    case tool(inputPorts: [BuildGraphInputPort])
    case configuration(_ configuration: String)
    case inputFile
    case outputFile(inputPorts: [BuildGraphInputPort])
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

        // A key part of a formula is the arguments that go to the preprocessor, compiler and linker, as well as which version and vendor to use.

        let standardClang = ToolDescriptor(name: "clang",
                                           version: "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                                           platform: "macOS",
                                           architecture: "arm64",
                                           recursiveHash: nil)

        let clangPreprocessorConfiguration = BuildGraphNode(name: "PreprocessorConfiguration",
                                                            kind: .configuration(try! ClangPreprocessorTool(toolDescriptor: standardClang,
                                                                                                            arguments: [],
                                                                                                            environment: [:]).toJSON()))

        let clangCompilerConfiguration = BuildGraphNode(name: "CompilerConfiguration",
                                                        kind: .configuration(try! ClangCompilerTool(toolDescriptor: standardClang,
                                                                                                    arguments: [],
                                                                                                    environment: [:]).toJSON()))

        let clangLinkerConfiguration = BuildGraphNode(name: "LinkerConfiguration",
                                                      kind: .configuration(try! ClangLinkerTool(toolDescriptor: standardClang,
                                                                                                arguments: [],
                                                                                                environment: [:]).toJSON()))

        let clangPreprocessorConfigurationOutputs = [BuildGraphInputWire(from: clangPreprocessorConfiguration, fromPort: "output")]
        let clangCompilerConfigurationOutputs = [BuildGraphInputWire(from: clangCompilerConfiguration, fromPort: "output")]
        let clangLinkerConfigurationOutputs = [BuildGraphInputWire(from: clangLinkerConfiguration, fromPort: "output")]

        let helloC = BuildGraphNode(name: "hello.c", kind: .inputFile)
        let helloH = BuildGraphNode(name: "hello.h", kind: .inputFile)
        let mainC = BuildGraphNode(name: "main.c", kind: .inputFile)
        let commonH = BuildGraphNode(name: "common.h", kind: .inputFile)

        let helloOutputs = [BuildGraphInputWire(from: helloC, fromPort: "output"),
                            BuildGraphInputWire(from: helloH, fromPort: "output"),
                            BuildGraphInputWire(from: commonH, fromPort: "output")]

        let mainOutputs = [BuildGraphInputWire(from: mainC, fromPort: "output"),
                           BuildGraphInputWire(from: helloH, fromPort: "output"),
                           BuildGraphInputWire(from: commonH, fromPort: "output")]

        let preprocessorHello = BuildGraphNode(name: "preprocessorHello",
                                               kind: .tool(inputPorts: [BuildGraphInputPort(name: "input", inputWires: helloOutputs),
                                                                        BuildGraphInputPort(name: "configuration", inputWires: clangPreprocessorConfigurationOutputs)]))

        let preprocessorMain = BuildGraphNode(name: "preprocessorMain",
                                              kind: .tool(inputPorts: [BuildGraphInputPort(name: "input", inputWires: mainOutputs),
                                                                       BuildGraphInputPort(name: "configuration", inputWires: clangPreprocessorConfigurationOutputs)]))

        let preprocessorHelloOutput = BuildGraphInputWire(from: preprocessorHello, fromPort: "output")
        let preprocessorMainOutput = BuildGraphInputWire(from: preprocessorMain, fromPort: "output")

        let compilerHello = BuildGraphNode(name: "compilerHello",
                                      kind: .tool(inputPorts: [BuildGraphInputPort(name: "input", inputWires: [preprocessorHelloOutput]),
                                                               BuildGraphInputPort(name: "configuration", inputWires: clangCompilerConfigurationOutputs)]))

        let compilerMain = BuildGraphNode(name: "compilerMain",
                                      kind: .tool(inputPorts: [BuildGraphInputPort(name: "input", inputWires: [preprocessorMainOutput]),
                                                               BuildGraphInputPort(name: "configuration", inputWires: clangCompilerConfigurationOutputs)]))

        let compilerHelloOutput = BuildGraphInputWire(from: compilerHello, fromPort: "output")
        let compilerMainOutput = BuildGraphInputWire(from: compilerMain, fromPort: "output")

        let linker = BuildGraphNode(name: "linker",
                                    kind: .tool(inputPorts: [BuildGraphInputPort(name: "input", inputWires: [compilerHelloOutput, compilerMainOutput]),
                                                             BuildGraphInputPort(name: "configuration", inputWires: clangLinkerConfigurationOutputs)]))

        let linkerOutput = [BuildGraphInputWire(from: linker, fromPort: "output")]

        let buildGraphDescription = BuildGraphDescription(
            outputs: [
                .init(name: "mylib.dylib",
                      kind: .outputFile(inputPorts: [BuildGraphInputPort(name: "input", inputWires: linkerOutput)]))])

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

    // Makes sure that all the children of the BuildGraphNode are mirrored by the NodeType. This means creating Wires and connecting
    // Nodes to them, then recursing into those Nodes to repeat the process.
    private func integrate(buildGraphNode: BuildGraphNode, currentNode: NodeType) throws {

        for inputPort in buildGraphNode.inputPorts() {
            for inputWire in inputPort.inputWires {

                var nodeConnectedToInputWire = try currentNode.findNodeConnectedToNodeViaInputWire(named: inputWire.from.name,
                                                                                                   fromPort: inputWire.fromPort)

                if nodeConnectedToInputWire == nil {
                    // The Wire or Node we want does not exist.

                    switch inputWire.from.kind {

                    case .configuration(let configuration):

                        nodeConnectedToInputWire = try nodeContext.processingCycle.rootNode.configurationFolder.childPoly(path: inputWire.from.name,
                                                                                                                          kind: StaticFileNode.kind,
                                                                                                                          createIfNotExist: true)

                        // HACK: copy across the configuration
                        let configurationNode = nodeConnectedToInputWire as! StaticFileNode
                        try configurationNode.writeToOutputPort(StaticFileNode.outputPort,
                                                                value: .init(originNodeID: configurationNode.nodeContext.nodeID!,
                                                                             kind: .value(dataObjectHash: configuration.intern(),
                                                                                          metadata: FileMetadata(name: "configuration"))))

                        if nodeConnectedToInputWire == nil {
                            // we could not create or resolve the Configuration node!
                            return
                        }

                    case .inputFile:

                        nodeConnectedToInputWire = try nodeContext.processingCycle.rootNode.inputFileSystem.childPoly(path: inputWire.from.name,
                                                                                                                      kind: StaticFileNode.kind,
                                                                                                                      createIfNotExist: false)

                        if nodeConnectedToInputWire == nil {
                            // we could not resolve the input file!
                            return
                        }

                    case .outputFile:
                        // should be impossible
                        return

                    case .tool:

                        nodeConnectedToInputWire = try nodeContext.processingCycle.rootNode.buildGraph.childPoly(path: inputWire.from.name,
                                                                                                                 kind: ToolNode.kind,
                                                                                                                 createIfNotExist: true)

                        if nodeConnectedToInputWire == nil {
                            // we could not resolve or create the tool!
                            return
                        }

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

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeMessage]?]) throws {
        let inputMessages = inputs[Self.formulaeInputPort]! ?? []

        for formulaFileMessage in inputMessages {
            switch formulaFileMessage.kind {

            case .valueMutated, .wireConnected:

                switch formulaFileMessage.originOutputPortValue.kind {

                case .noValue:
                    break

                case .value(let dataObjectHash, let metdata):
                    try integrateFormula(formula: dataObjectHash.resolveAsString()!)
                }

            case .error:
                break

            case .wireDisconnected:
                print("wire disconnected")

            }
        }
    }
}


extension BuildGraphNode {
    func inputPorts() -> [BuildGraphInputPort] {
        switch kind {

        case .tool(let inputPorts):
            return inputPorts

        case .outputFile(let inputPorts):
            return inputPorts

        case .configuration, .inputFile:
            return []
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

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeMessage]?]) throws {
        let inputMessages = inputs[Self.fileListInputPort]! ?? []

        for fileListMessage in inputMessages {
            switch fileListMessage.kind {

            case .valueMutated(let delta):
                if let delta {
                    let string = delta.resolveAsString()!
                    let message = try PolyFactory.decode(encodedJSON: string)

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
    func processInputs(node: ToolNode, inputs: [NodeKindDescriptor.InputPort: [NodeMessage]?], nodeContext: NodeContext) throws
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

    init(toolDescriptor: ToolDescriptor, arguments: [String], environment: [String: String]) throws {
        self.toolDescriptor = toolDescriptor
        self.arguments = arguments
        self.environment = environment
    }

    static let kind: UInt = 13


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

    func processInputs(node: ToolNode, inputs: [NodeKindDescriptor.InputPort: [NodeMessage]?], nodeContext: NodeContext) throws {

        guard let firstInputValue = try node.readFromInputPort(ToolNode.input).first else {
            return
        }

        switch firstInputValue.kind {

        case .noValue:
            try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                     kind: .noValue(reason: .awaitingDependency)))
            return

        case .value(let dataObjectHash, let metadata):

            let bytes = dataObjectHash.resolve()!

            var output: [UInt8] = []

            let inputFilename: String

            // BUG this never has metadata
            if let fileMetadata = metadata as? FileMetadata {
                inputFilename = fileMetadata.name
            } else {
                inputFilename = "source.pc"
            }

            let outputFilename = inputFilename + ".o"

            var arguments = [String]()

            arguments.append("-x")
            arguments.append("c")
            arguments.append("-c")
            arguments.append(inputFilename)
            arguments.append("-o")
            arguments.append(outputFilename)
            arguments.append("-target")
            arguments.append("arm64-apple-macos14.0")

            arguments.append(contentsOf: self.arguments)

            let tool = try ToolExecutorRegistry.instance.tool(descriptor: toolDescriptor)

            let exitCode = try tool.execute(arguments: arguments,
                                            environment: environment,
                                            inputFiles: [.init(filePath: inputFilename, content: bytes)],
                                            expectedOutputFileNames: [outputFilename],
                                            output: .init(logError: { error in print(error) },
                                                          logMessage: { message in print(message) },
                                                          write: { filePath, data in output.append(contentsOf: data) }))

            if exitCode == 0 {
                try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                         kind: .value(dataObjectHash: output.intern(),
                                                                                      metadata: FileMetadata(name: outputFilename))))
            } else {
                try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                         kind: .noValue(reason: .error(stack: []))))
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

    init(toolDescriptor: ToolDescriptor, arguments: [String], environment: [String: String]) throws {
        self.toolDescriptor = toolDescriptor
        self.arguments = arguments
        self.environment = environment
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

    func processInputs(node: ToolNode, inputs: [NodeKindDescriptor.InputPort: [NodeMessage]?], nodeContext: NodeContext) throws {

        let inputValues: [NodeValue]  = try node.readFromInputPort(ToolNode.input)

        guard inputValues.count > 0 else {
            try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                     kind: .noValue(reason: .awaitingDependency)))
            return
        }

        // when the .c file changes or is set for the first time:
        // load the .c file and recursively discover all includes using a regex per file
        // use this list of header files to create wires to the Input File System's nodes,
        // if they do not already exist.
        // if there are wires not in the list, remove them.
        // once the contents of all newly-wired-in header files are ready to be read,
        // do a run of the preprocessor with the flag that causes it to emit a tree of all
        // actually-used include files, remembering that some may be conditionally excluded
        // compare that list of actually-used files with the wires and delete any unneeded wires
        
        // when a header wire is deleted: treat it as though the .c file was modified
        // when a header wire is added: treat it as though the .c file was modified
        // when a header file is modified: treat it as though the .c file was modified
        
        // the problem with the above is the rescanning of files that have not changed.
        // this could avoided by having a "includes" wire output from every .c and .h file that
        // benefits from the built-in caching. The "includes" output would be updated whenever
        // the file changes and would contain the list of included files. The preprocessor node
        // would then read from the "includes" output to determine which header files to read
        // and feed into the preprocessor, without having to re-scan the .c file for includes
        // on every change. We would accept that some unused headers might be fed into the
        // preprocessor, but that would be a performance win over rescanning and re-wiring on every change.
        
        
        // Find the primary C source file among inputs.
        // Avoid throwing inside the sequence algorithms to keep type inference unambiguous.
        let primarySourceFile: NodeValue? = inputValues.first { nodeValue in
            switch nodeValue.kind {
            case .noValue:
                return false
            case .value(_, let metadata):
                if let fileMetadata = metadata as? FileMetadata {
                    return fileMetadata.name.hasSuffix(".c")
                }
            }
            return false
        }

        guard let primarySourceFile else {
            try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                     kind: .noValue(reason: .awaitingDependency)))
            return
        }

        // Collect header files (.h) alongside their full sandbox paths.
        // Use a non-throwing predicate and make the closure's return type explicit to help the compiler.
        let headerFiles: [FileNameAndContent] = inputValues
            .filter { (nodeValue) -> Bool in
                return (try? nodeValue.isFileWithExtension(".h", processingCycle: nodeContext.processingCycle)) ?? false
            }
            .compactMap { (nodeValue) -> FileNameAndContent? in
                switch nodeValue.kind {
                case .value(let dataObjectHash, let metadata):
                    guard let data = dataObjectHash.resolve() else { return nil }
                    // TODO: may not come from StaticFileNode.
                    guard let staticFileNode: StaticFileNode = try? nodeContext.processingCycle.node(nodeID: nodeValue.originNodeID) else { return nil }
                    let filePath = (try? staticFileNode.buildFullPathName()) ?? "header.h"
                    return FileNameAndContent(filePath: filePath, content: data)
                case .noValue:
                    return nil
                }
            }

        switch primarySourceFile.kind {

        case .noValue:
            try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                     kind: .noValue(reason: .awaitingDependency)))
            return

        case .value(let dataObjectHash, let metadata):

            let bytes = dataObjectHash.resolve()!

            var output: [UInt8] = []

            let fileMetadata = metadata as! FileMetadata

            let inputFilename = fileMetadata.name
            let outputFilename = fileMetadata.name + ".p"

            var arguments = [String]()

            // Preprocess only: -E tells clang to run only the preprocessor and output the result.
            arguments.append("-E")

            // Treat the input as C source.
            arguments.append("-x")
            arguments.append("c")

            // Search the sandbox working directory for #include'd headers.
            arguments.append("-I")
            arguments.append(".")

/*          TODO  for includePath in includePaths {
                arguments.append("-I")
                arguments.append(includePath)
            }
*/
            // TODO standard includes are read-only and therefore won't change and require rebuilding. However,
            // we need to guarantee that a particular set of headers are unadulterated. We need a concept
            // of a ZIPed, versioned and hashed system-headers directory tree.
            arguments.append("-I")
            arguments.append("/Applications/Xcode_26_2.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include")

            //arguments.append("-v")
            //arguments.append("-H")

            // Do not search system include paths — all headers must be explicitly provided
            // via inputFiles to maintain hermeticity.
            arguments.append("-nostdinc")

            // Target triple.
            arguments.append("-target")
            arguments.append("arm64-apple-macos14.0")

            // Input file (the .c source).
            arguments.append(inputFilename)

            // Output file (the preprocessed result).
            arguments.append("-o")
            arguments.append(outputFilename)

            arguments.append(contentsOf: self.arguments)

            let tool = try ToolExecutorRegistry.instance.tool(descriptor: toolDescriptor)

            var inputFiles: [FileNameAndContent] = [.init(filePath: inputFilename, content: bytes)]
            inputFiles.append(contentsOf: headerFiles)

            let exitCode = try tool.execute(arguments: arguments,
                                            environment: environment,
                                            inputFiles: inputFiles,
                                            expectedOutputFileNames: [outputFilename],
                                            output: .init(logError: { error in print(error) },
                                                          logMessage: { message in print(message) },
                                                          write: { filePath, data in output.append(contentsOf: data) }))

            if exitCode == 0 {
                try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                         kind: .value(dataObjectHash: output.intern(),
                                                                                      metadata: FileMetadata(name: outputFilename))))
            } else {
                try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                         kind: .noValue(reason: .error(stack: []))))
            }
        }
    }
}

extension NodeValue {
    func isFileWithExtension(_ ext: String, processingCycle: ProcessingCycle) throws -> Bool {
        switch kind {

        case .value:
            guard let staticFileNode = try processingCycle.nodePoly(nodeID: originNodeID) as? StaticFileNode else {
                return false
            }

            return staticFileNode.nodeContext.name?.hasSuffix(ext) ?? false

        default:
            return false
        }

    }
}

final class ClangLinkerTool: Tool {

    let toolDescriptor: ToolDescriptor!
    let arguments: [String]
    let environment: [String: String]

    required init() throws {
        toolDescriptor = nil
        arguments = []
        environment = [:]
    }

    init(toolDescriptor: ToolDescriptor, arguments: [String], environment: [String: String]) throws {
        self.toolDescriptor = toolDescriptor
        self.arguments = arguments
        self.environment = environment
    }

    static let kind: UInt = 12

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

    func processInputs(node: ToolNode, inputs: [NodeKindDescriptor.InputPort: [NodeMessage]?], nodeContext: NodeContext) throws {

        let inputValues = try node.readFromInputPort(ToolNode.input)

        var libraryFiles: [FileNameAndContent] = []

        for nodeValue in inputValues {
            switch nodeValue.kind {

            case .value(let dataObjectHash, let metadata):

                if let fileMetadata = metadata as? FileMetadata, fileMetadata.name.hasSuffix(".dylib") {

                    let originNode = try nodeContext.processingCycle.nodePoly(nodeID: nodeValue.originNodeID)

                    if let data = dataObjectHash.resolve() {
                        if let staticFileNode = originNode as? StaticFileNode {
                            // Static file: use the path
                            libraryFiles.append(FileNameAndContent(filePath: try staticFileNode.buildFullPathName(), content: data))
                        } else {
                            // A generated output from a node
                            libraryFiles.append(FileNameAndContent(filePath: fileMetadata.name, content: data))
                        }
                    }
                }

            case .noValue:
                try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                         kind: .noValue(reason: .error(stack: [])))) // TODO
                return
            }
        }

        var objectFiles: [FileNameAndContent] = []

        for nodeValue in inputValues {
            switch nodeValue.kind {
            case .value(let dataObjectHash, let metadata):
                if let fileMetadata = metadata as? FileMetadata, fileMetadata.name.hasSuffix(".o") {
                    if let data = dataObjectHash.resolve() {
                        objectFiles.append(FileNameAndContent(filePath: fileMetadata.name, content: data))
                    }
                }

            case .noValue:
                try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                         kind: .noValue(reason: .error(stack: [])))) // TODO
                return
            }
        }

        if objectFiles.count == 0 {
            try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                     kind: .noValue(reason: .error(stack: [])))) // TODO
            return
        }
        var output: [UInt8] = []

        var arguments = [String]()

        arguments.append(contentsOf: self.arguments)

        // Produce a dynamic library.
//        arguments.append("-dynamiclib")

        // Target triple.
        arguments.append("-target")
        arguments.append("arm64-apple-macos14.0")

        // Search the sandbox working directory for libraries.
        arguments.append("-L")
        arguments.append(".")

        // TODO: lock down version, hash
        arguments.append("-L")
        arguments.append("/Applications/Xcode_26_2.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib")

        arguments.append("-lSystem")

        // Do not link the standard library — all dependencies must be explicitly provided
        // via inputFiles to maintain hermeticity.
        arguments.append("-nostdlib")

        // Add each object file by name.
        for objectFile in objectFiles {
            arguments.append(objectFile.filePath)
        }

        // Link each dynamic library by name.
        // Clang expects -l<name> where the file is lib<name>.dylib,
        // but since our files may not follow that convention, pass them directly as inputs.
        for libraryFile in libraryFiles {
            arguments.append(libraryFile.filePath)
        }

        // Output file.
        arguments.append("-o")
        arguments.append("output.dylib")

        arguments.append(contentsOf: self.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: toolDescriptor)

        var inputFiles: [FileNameAndContent] = []
        inputFiles.append(contentsOf: libraryFiles)
        inputFiles.append(contentsOf: objectFiles)

        let exitCode = try tool.execute(arguments: arguments,
                                        environment: environment,
                                        inputFiles: inputFiles,
                                        expectedOutputFileNames: ["output.dylib"],
                                        output: .init(logError: { error in print(error) },
                                                      logMessage: { message in print(message) },
                                                      write: { filePath, data in output.append(contentsOf: data) }))

        if exitCode == 0 {
            try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                     kind: .value(dataObjectHash: output.intern(),
                                                                                  metadata: FileMetadata(name: "output.dylib"))))
        } else {
            try node.writeToOutputPort(ToolNode.output, value: .init(originNodeID: nodeContext.nodeID!,
                                                                     kind: .noValue(reason: .error(stack: []))))
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

        switch configurationValue.kind {

        case .noValue:
            return nil

        case .value(let dataObjectHash, let metadata):

            guard let data = dataObjectHash.resolve() else {
                return nil
            }

            let configurationString = String(decoding: data, as: Unicode.UTF8.self)
            let tool = try PolyFactory.decode(encodedJSON: configurationString) as! Tool?
            return tool
        }
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeMessage]?]) throws {

        guard let tool = try makeTool() else {
            try writeToOutputPort(Self.output, value: .init(originNodeID: nodeContext.nodeID!, kind: .noValue(reason: .awaitingDependency)))
            return
        }

        try tool.processInputs(node: self, inputs: inputs, nodeContext: nodeContext)
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

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeMessage]?]) throws {
        let inputMessages = inputs[Self.formulaFileInputPort]! ?? []

        for formulaFileMessage in inputMessages {
            switch formulaFileMessage.kind {

            case .valueMutated, .wireConnected:

                switch formulaFileMessage.originOutputPortValue.kind {

                case .noValue:
                    break

                case .value(let dataObjectHash, let metadata):
                    // This extractor just passes through
                    try writeToOutputPort(Self.formulaOutputPort, value: .init(originNodeID: nodeContext.nodeID!,
                                                                               kind: .value(dataObjectHash: dataObjectHash,
                                                                                            metadata: FileMetadata(name: "formula"))))

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

    func tool(descriptor: ToolDescriptor) throws -> ToolExecutor {

        guard let tool = toolsByDescriptor[descriptor] else {
            throw ToolError.noMatchingToolFound
        }

        return tool
    }
}

enum ToolError: Error {
    case noMatchingToolFound
}

class DefaultTools {
    // TODO: in the future this would search the file system (or container's file system) for all known tools and register them,
    // but for now we will just hardcode clang as an example
    static func setup(toolExecutorRegistry: ToolExecutorRegistry) throws {
        try toolExecutorRegistry.registerTool(descriptor: .init(name: "clang",
                                                                version: "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                                                                platform: "macOS",
                                                                architecture: "arm64",
                                                                recursiveHash: nil),
                                               toolExecutor: LocalFileSystemTool(localPath: "/usr/bin/clang"))
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
    let filePath: String
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

        print("Executing tool in sandbox path: \(sandboxPath)")

        // 2. Write all input files into the sandbox.
        //    Intermediate directories are created as needed so that relative paths like "src/main.c" work.

        for inputFile in inputFiles {
            let inputFileURL = Foundation.URL(fileURLWithPath: sandboxPath).appendingPathComponent(inputFile.filePath)
            let containingDirectory = inputFileURL.deletingLastPathComponent().path

            do {
                if !fileManager.fileExists(atPath: containingDirectory) {
                    try fileManager.createDirectory(atPath: containingDirectory, withIntermediateDirectories: true)
                }
                try Foundation.Data(inputFile.content).write(to: inputFileURL)
            } catch {
                throw ToolExecutionError.failedToWriteInputFile(fileName: inputFile.filePath, underlying: error)
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




// Takes a .c or .h as input and outputs a list of paths to include files, ignoring system includes.
final class IncludeFinder: NodeType {
    static let kind: UInt = 15

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

    static let sourceFileInputPort = NodeKindDescriptor.InputPort(index: 0,
                                                                  name: "sourceFile",
                                                                  kind: .value(dataType: .utf8Text),
                                                                  maximumConnections: 1,
                                                                  minimumConnections: 1)

    static let includePathListOutputPort = NodeKindDescriptor.OutputPort(index: 0,
                                                                         name: "includePathList",
                                                                         kind: .value(dataType: .utf8Text))

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [Self.sourceFileInputPort], outputs: [Self.includePathListOutputPort])
    }

    private func extractIncludePaths(sourceFileContent: String) -> [String] {
        [] // TODO: scan for all #include statements in the given input file, which is a .c or .h file, and return their paths. Ignore includes with angle brackets.
    }

    func processInputs(_ inputs: [NodeKindDescriptor.InputPort: [NodeMessage]?]) throws {
        let inputMessages = inputs[Self.sourceFileInputPort]! ?? []

        for inputMessage in inputMessages {
            switch inputMessage.kind {

            case .valueMutated:

                switch inputMessage.originOutputPortValue.kind {
                case .value(let dataObjectHash, let metadata):
                    let inputFileContent = dataObjectHash.resolveAsString()!
                    let includePathList = extractIncludePaths(sourceFileContent: inputFileContent).joined(separator: "\n")

                    try writeToOutputPort(Self.includePathListOutputPort, value: .init(originNodeID: nodeContext.nodeID!,
                                                                                       kind: .value(dataObjectHash: includePathList.intern(),

                                                                                                    metadata: FileMetadata(name: "includePathList"))))
                case .noValue:
                    try writeToOutputPort(Self.includePathListOutputPort, value: .init(originNodeID: nodeContext.nodeID!,
                                                                                       kind: .noValue(reason: .error(stack: []))))
                    break
                }

                break

            case .error:
                try writeToOutputPort(Self.includePathListOutputPort, value: .init(originNodeID: nodeContext.nodeID!,
                                                                                   kind: .noValue(reason: .error(stack: []))))
                break

            case .wireConnected:
                print("wire connected")

            case .wireDisconnected:
                print("wire disconnected")

            }
        }
    }
}
