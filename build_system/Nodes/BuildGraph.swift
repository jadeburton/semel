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

    static let formulaeInputPort = InputPort(index: 0,
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

                // We are walking from the current BuildGraphNode to its children

                let searchKey = try inputWire.from.toJSON()

                // do a database search of all the BuildGraph children using the formula as the searchKey

                let rawNodes = try nodeContext.processingCycle.database.selectNodes(searchKey: searchKey,
                                                                                    parentNodeID: self.nodeContext.nodeID!)

                func createOrGetNode() throws -> any NodeType {
                    if rawNodes.isEmpty {
                        // No existing nodes match this child BuildGraphNode, so we need to create a new one

                        switch inputWire.from.kind {

                        case .configuration(let configuration):
                            let nodeConnectedToInputWire = try nodeContext.processingCycle.rootNode.buildGraph.childPoly(path: inputWire.from.name,
                                                                                                                         kind: StaticFileNode.kind,
                                                                                                                         createIfNotExist: true)!

                            let configurationNode = nodeConnectedToInputWire as! StaticFileNode

                            try configurationNode.writeToOutputPort(StaticFileNode.outputPort, value: .value(configuration.intern()))
                            return nodeConnectedToInputWire

                        case .tool(let kind, _):
                            return try nodeContext.processingCycle.rootNode.buildGraph.childPoly(path: inputWire.from.name,
                                                                                                 kind: kind.asPolySerializableKind(),
                                                                                                 createIfNotExist: true)!

                        case .inputFile:
                            return try nodeContext.processingCycle.rootNode.inputFileSystem.childPoly(path: inputWire.from.name,
                                                                                                      kind: StaticFileNode.kind,
                                                                                                      createIfNotExist: true)!

                        case .outputFile:
                            // should be impossible
                            throw BuildGraphError.invalidPortNodeKind

                        }

                    } else {
                        if rawNodes.count > 1 {
                            throw BuildGraphError.multipleMatchingNodesBySearchKey
                        }

                        let rawNode = rawNodes[0]

                        // connect to the existing node....
                        return try nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: rawNode)
                    }
                }

                let nodeConnectedToInputWire = try createOrGetNode()

                nodeConnectedToInputWire.nodeContext.searchKey = searchKey
                try nodeConnectedToInputWire.save()

                guard let toPort = currentNode.descriptor.inputPort(named: inputPort.name) else {
                    print("ERROR: Could not find input port named '\(inputPort.name)' on \(type(of: currentNode))")
                    throw BuildGraphError.unknownInputPortNameReference
                }

                try nodeContext.processingCycle.connectWire(fromNode: nodeConnectedToInputWire,
                                                            fromPort: nodeConnectedToInputWire.descriptor.outputPort(named: inputWire.fromPort)!,
                                                            toNode: currentNode,
                                                            toPort: toPort)

                try integrate(buildGraphNode: inputWire.from, currentNode: nodeConnectedToInputWire)

            }
        }
    }

    private func cascadeDeleteFromOutputFile(_ outputFile: StaticFileNode) throws {
        guard let outputNodeID = outputFile.nodeContext.nodeID else { return }
        var visited = Set<ObjectID>()
        try cascadeDeleteUpstreamNode(nodeID: outputNodeID, visited: &visited)
    }

    /// Recursively deletes `nodeID` and any upstream node that exclusively feeds it
    /// (i.e. has no other consumers). Nodes under `inputFileSystem` are never deleted —
    /// they are user-provided source files that persist independently of any formula.
    private func cascadeDeleteUpstreamNode(nodeID: ObjectID, visited: inout Set<ObjectID>) throws {
        guard !visited.contains(nodeID) else { return }
        visited.insert(nodeID)

        let database = nodeContext.processingCycle.database
        let incomingWires = try database.selectWires(goingToNodeID: nodeID)

        for wire in incomingWires {
            let sourceNodeID = wire.fromNodeID

            let currentRaw = try database.selectNodeByID(sourceNodeID)!

            // Skip nodes outside of BuildGraph — those should not be deleted by a formula cascade delete.
            if try (currentRaw.parentNodeID == nodeContext.nodeID) || (currentRaw.parentNodeID == outputFileSystem.nodeContext.nodeID) {
                // Only cascade-delete the source if this formula's output is its sole consumer.
                let allOutgoingWiresFromSource = try database.selectWires(comingFromNodeID: sourceNodeID)

                if allOutgoingWiresFromSource.count <= 1 {
                    try cascadeDeleteUpstreamNode(nodeID: sourceNodeID, visited: &visited)
                }
            }
        }

        // deleteNode cleans up all incoming and outgoing wires for this node.
        _ = try nodeContext.processingCycle.deleteNode(nodeID)
    }

    // MARK: Process

    func process() throws {

        let allFormulae = try readAllValuesFromInputPort(Self.formulaeInputPort)

        let decodedFormulae = try allFormulae.map { formulaFileValue in
            switch formulaFileValue.kind {
            case .noValue:
                throw NodeError.missingInputs
            case .value(let dataObjectHash):
                return try BuildGraphNode.fromJSON(dataObjectHash.resolveAsString())
            }
        }

        for formula in decodedFormulae {
            try integrate(buildGraphOutput: formula)
        }

        // iterate output artifacts on the graph and find those that have no corresponding formula anymore. cascade-delete these artifacts.
        for outputFiles in try self.outputFileSystem.allChildren() {
            if let outputFile = outputFiles as? StaticFileNode {
                if !decodedFormulae.contains(where: { formula in formula.name == outputFile.nodeContext.name }) {
                    try cascadeDeleteFromOutputFile(outputFile)
                }
            }
        }
    }
}


extension BuildGraphNode {

    static func generateSimpleFormula(sourceFiles: [String], productName: String, dynamicLibrary: Bool) throws -> BuildGraphNode {

        let standardClang = ToolDescriptor(name: "clang",
                                           version: "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                                           platform: "macOS",
                                           architecture: "arm64",
                                           recursiveHash: nil)

        // Shared tool configuration nodes (one per tool kind, reused by all source files)
        let clangPreprocessorConfiguration = BuildGraphNode(
            name: "PreprocessorConfiguration",
            kind: .configuration(try ClangPreprocessorToolConfiguration(
                toolDescriptor: standardClang, arguments: [], environment: [:]).toJSON()))

        let clangCompilerConfiguration = BuildGraphNode(
            name: "CompilerConfiguration",
            kind: .configuration(try ClangCompilerToolConfiguration(
                toolDescriptor: standardClang, arguments: [], environment: [:]).toJSON()))

        let clangLinkerConfiguration = BuildGraphNode(
            name: "LinkerConfiguration",
            kind: .configuration(try ClangLinkerToolConfiguration(toolDescriptor: standardClang,
                                                                  arguments: dynamicLibrary ? ["-dynamiclib"] : [],
                                                                  environment: [:]).toJSON()))

        // Convenience: single-element wire arrays for the shared configuration nodes
        let clangPreprocessorConfigurationWires = [BuildGraphInputWire(from: clangPreprocessorConfiguration, fromPort: "output")]
        let clangCompilerConfigurationWires     = [BuildGraphInputWire(from: clangCompilerConfiguration,     fromPort: "output")]
        let clangLinkerConfigurationWires       = [BuildGraphInputWire(from: clangLinkerConfiguration,       fromPort: "output")]

        // One input-file node per source file (e.g. hello.c, main.c)
        let sourceFileNodes = sourceFiles.map { sourceFile in
            BuildGraphNode(name: sourceFile, kind: .inputFile)
        }

        // One preprocessor node per source file, connected to the source file and the shared config
        let preprocessorNodes = sourceFileNodes.map { sourceFileNode in
            BuildGraphNode(
                name: "preprocessor(\(sourceFileNode.name))",
                kind: .tool(kind: .preprocessor,
                            inputPorts: [
                                BuildGraphInputPort(name: "input",
                                                   inputWires: [BuildGraphInputWire(from: sourceFileNode, fromPort: "output")]),
                                BuildGraphInputPort(name: "configuration",
                                                   inputWires: clangPreprocessorConfigurationWires)
                            ]))
        }

        // One compiler node per preprocessor, connected to the preprocessed output and the shared config
        let compilerNodes = preprocessorNodes.map { preprocessorNode in
            BuildGraphNode(
                name: "compiler(\(preprocessorNode.name))",
                kind: .tool(kind: .compiler,
                            inputPorts: [
                                BuildGraphInputPort(name: "input",
                                                   inputWires: [BuildGraphInputWire(from: preprocessorNode, fromPort: "output")]),
                                BuildGraphInputPort(name: "configuration",
                                                   inputWires: clangCompilerConfigurationWires)
                            ]))
        }

        // The linker takes all compiler outputs as inputs, plus the shared linker configuration
        let linkerInputWires = compilerNodes.map { compilerNode in
            BuildGraphInputWire(from: compilerNode, fromPort: "output")
        }

        let linkerNode = BuildGraphNode(
            name: "linker(\(productName))",
            kind: .tool(kind: .linker,
                        inputPorts: [
                            BuildGraphInputPort(name: "input",         inputWires: linkerInputWires),
                            BuildGraphInputPort(name: "configuration", inputWires: clangLinkerConfigurationWires)
                        ]))

        // The output file node, wired from the linker
        return BuildGraphNode(
            name: productName,
            kind: .outputFile(inputPorts: [
                BuildGraphInputPort(name: "input",
                                   inputWires: [BuildGraphInputWire(from: linkerNode, fromPort: "output")])
            ]))
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
