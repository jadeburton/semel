//
//  BuildGraph.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

// MARK: - BuildGraph

final class BuildGraph: NodeType {
    static let kind: UInt = 2

    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {}

    required init() {}

    required init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
    }

    // MARK: Ports

    static let formulaeInputPort = NodeKindDescriptor.InputPort(index: 0,
                                                                name: "formulae",
                                                                kind: .value(dataType: .utf8Text),
                                                                maximumConnections: nil,
                                                                minimumConnections: 0,
                                                                cascadingDelete: false)

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind, inputs: [Self.formulaeInputPort], outputs: [])
    }

    // MARK: File-system children

    var outputFileSystem: FolderNode {
        get throws {
            try child(named: "outputFileSystem", createIfNotExist: true)!
        }
    }

    // MARK: Debug

    func debugPrintTree() {
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

        let database = nodeContext.processingCycle.database
        guard let nodeID = node.nodeContext.nodeID else { return }

        do {
            let incomingWires = try database.selectWires(goingToNodeID: nodeID)

            var visitedDependencyNodeIDs = Set<ObjectID>()
            var dependencyNodes = [NodeType]()

            for wire in incomingWires {
                guard !visitedDependencyNodeIDs.contains(wire.fromNodeID) else { continue }
                visitedDependencyNodeIDs.insert(wire.fromNodeID)

                if let rawNode = try? database.selectNodeByID(wire.fromNodeID),
                   let dependencyNode = try? nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: rawNode) {
                    dependencyNodes.append(dependencyNode)
                }
            }

            for dependencyNode in dependencyNodes {
                printDependencyTree(node: dependencyNode, indentLevel: indentLevel + 1)
            }
        } catch {
            print("\(indent)  (error loading dependencies: \(error))")
        }
    }

    // MARK: Formula integration

    func integrateFormula(formula: String) throws {
        print("integrate formula: \(formula)")

        let standardClang = ToolDescriptor(name: "clang",
                                           version: "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                                           platform: "macOS",
                                           architecture: "arm64",
                                           recursiveHash: nil)

        let clangPreprocessorConfiguration = BuildGraphNode(
            name: "PreprocessorConfiguration",
            kind: .configuration(try! ClangPreprocessorToolConfiguration(
                toolDescriptor: standardClang, arguments: [], environment: [:]).toJSON()))

        let clangCompilerConfiguration = BuildGraphNode(
            name: "CompilerConfiguration",
            kind: .configuration(try! ClangCompilerToolConfiguration(
                toolDescriptor: standardClang, arguments: [], environment: [:]).toJSON()))

        let clangLinkerConfiguration = BuildGraphNode(
            name: "LinkerConfiguration",
            kind: .configuration(try! ClangLinkerToolConfiguration(
                toolDescriptor: standardClang, arguments: [], environment: [:]).toJSON()))

        let clangPreprocessorConfigurationOutputs = [BuildGraphInputWire(from: clangPreprocessorConfiguration, fromPort: "output")]
        let clangCompilerConfigurationOutputs     = [BuildGraphInputWire(from: clangCompilerConfiguration,     fromPort: "output")]
        let clangLinkerConfigurationOutputs       = [BuildGraphInputWire(from: clangLinkerConfiguration,       fromPort: "output")]

        let helloC  = BuildGraphNode(name: "hello.c",  kind: .inputFile)
        let mainC   = BuildGraphNode(name: "main.c",   kind: .inputFile)

        let helloOutputs = [BuildGraphInputWire(from: helloC,  fromPort: "output")]
        let mainOutputs  = [BuildGraphInputWire(from: mainC,   fromPort: "output")]

        let preprocessorHello = BuildGraphNode(
            name: "preprocessorHello",
            kind: .tool(kind: .preprocessor,
                        inputPorts: [BuildGraphInputPort(name: "input",         inputWires: helloOutputs),
                                     BuildGraphInputPort(name: "configuration", inputWires: clangPreprocessorConfigurationOutputs)]))

        let preprocessorMain = BuildGraphNode(
            name: "preprocessorMain",
            kind: .tool(kind: .preprocessor,
                        inputPorts: [BuildGraphInputPort(name: "input",         inputWires: mainOutputs),
                                     BuildGraphInputPort(name: "configuration", inputWires: clangPreprocessorConfigurationOutputs)]))

        let preprocessorHelloOutput = BuildGraphInputWire(from: preprocessorHello, fromPort: "output")
        let preprocessorMainOutput  = BuildGraphInputWire(from: preprocessorMain,  fromPort: "output")

        let compilerHello = BuildGraphNode(
            name: "compilerHello",
            kind: .tool(kind: .compiler,
                        inputPorts: [BuildGraphInputPort(name: "input",         inputWires: [preprocessorHelloOutput]),
                                     BuildGraphInputPort(name: "configuration", inputWires: clangCompilerConfigurationOutputs)]))

        let compilerMain = BuildGraphNode(
            name: "compilerMain",
            kind: .tool(kind: .compiler,
                        inputPorts: [BuildGraphInputPort(name: "input",         inputWires: [preprocessorMainOutput]),
                                     BuildGraphInputPort(name: "configuration", inputWires: clangCompilerConfigurationOutputs)]))

        let compilerHelloOutput = BuildGraphInputWire(from: compilerHello, fromPort: "output")
        let compilerMainOutput  = BuildGraphInputWire(from: compilerMain,  fromPort: "output")

        let linker = BuildGraphNode(
            name: "linker",
            kind: .tool(kind: .linker,
                        inputPorts: [BuildGraphInputPort(name: "input",         inputWires: [compilerHelloOutput, compilerMainOutput]),
                                     BuildGraphInputPort(name: "configuration", inputWires: clangLinkerConfigurationOutputs)]))

        let buildGraphDescription = BuildGraphNode(name: "mylib.dylib",
                                                   kind: .outputFile(inputPorts: [BuildGraphInputPort(name: "input",
                                                                                                      inputWires: [BuildGraphInputWire(from: linker, fromPort: "output")])]))

        try integrate(buildGraphOutput: buildGraphDescription)
    }

    private func integrate(buildGraphOutput: BuildGraphNode) throws {
        try integrate(buildGraphNode: buildGraphOutput,
                      currentNode: try outputFileSystem.child(path: buildGraphOutput.name,
                                                              createIfNotExist: true)! as StaticFileNode)
    }

    /// Recursively ensures that all children of `buildGraphNode` are mirrored by live
    /// nodes and wires in the processing graph.
    private func integrate(buildGraphNode: BuildGraphNode, currentNode: NodeType) throws {
        for inputPort in buildGraphNode.inputPorts() {
            for inputWire in inputPort.inputWires {

                var nodeConnectedToInputWire = try currentNode.findNodeConnectedToNodeViaInputWire(
                    named: inputWire.from.name, fromPort: inputWire.fromPort)

                if nodeConnectedToInputWire == nil {
                    switch inputWire.from.kind {

                    case .configuration(let configuration):
                        nodeConnectedToInputWire = try nodeContext.processingCycle.rootNode
                            .configurationFolder.childPoly(path: inputWire.from.name,
                                                           kind: StaticFileNode.kind,
                                                           createIfNotExist: true)
                        let configurationNode = nodeConnectedToInputWire as! StaticFileNode
                        try configurationNode.writeToOutputPort(
                            StaticFileNode.outputPort,
                            value: .value(.dataObjectHash(configuration.intern()),
                                          metadata: FileMetadata(name: "configuration")))
                        if nodeConnectedToInputWire == nil { return }

                    case .inputFile:
                        nodeConnectedToInputWire = try nodeContext.processingCycle.rootNode
                            .inputFileSystem.childPoly(path: inputWire.from.name,
                                                       kind: StaticFileNode.kind,
                                                       createIfNotExist: true)
                        if nodeConnectedToInputWire == nil { return }

                    case .outputFile:
                        return  // should be impossible

                    case .tool(let kind, _):
                        nodeConnectedToInputWire = try nodeContext.processingCycle.rootNode
                            .buildGraph.childPoly(path: inputWire.from.name,
                                                  kind: kind.asPolySerializableKind(),
                                                  createIfNotExist: true)
                        if nodeConnectedToInputWire == nil { return }
                    }
                }

                guard let toPort = currentNode.descriptor.inputPort(named: inputPort.name) else {
                    print("ERROR: Could not find input port named '\(inputPort.name)' on \(type(of: currentNode))")
                    throw BuildGraphError.unknownInputPortNameReference
                }

                try nodeContext.processingCycle.connectWire(
                    fromNode: nodeConnectedToInputWire!,
                    fromPort: nodeConnectedToInputWire!.descriptor.outputPort(named: inputWire.fromPort)!,
                    toNode: currentNode,
                    toPort: toPort)

                try integrate(buildGraphNode: inputWire.from, currentNode: nodeConnectedToInputWire!)
            }
        }
    }

    // MARK: Process

    func process() throws {
        for formulaFileValue in try readAllValuesFromInputPort(Self.formulaeInputPort) {
            switch formulaFileValue.kind {
            case .noValue:
                break
            case .value(let payload, _):
                try integrateFormula(formula: payload.expectDataObjectHash().resolveAsString())
            }
        }
    }
}

extension BuildGraphToolKind {
    func asPolySerializableKind() -> UInt {
        switch self {
        case .preprocessor: return ClangPreprocessorTool.kind
        case .compiler: return ClangCompilerTool.kind
        case .linker: return ClangLinkerTool.kind
        }
    }
}

// MARK: - NodeValuePayload helpers

enum NodeValueError: Error {
    case nodeValueIsNotDataObjectHash
}

extension NodeValuePayload {
    func expectDataObjectHash() throws -> DataObjectHash {
        switch self {
        case .dataObjectHash(let dataObjectHash):
            return dataObjectHash
        case .stream:
            throw NodeValueError.nodeValueIsNotDataObjectHash
        }
    }
}
