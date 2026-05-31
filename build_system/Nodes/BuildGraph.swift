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
//        print("integrate formula: \(formula)")
/*
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

        let json = try JSONEncoder().encode(buildGraphDescription)
        print("build graph description JSON: \(String(data: json, encoding: .utf8) ?? "nil") ")
*/
//        let buildGraphDescription = try JSONDecoder().decode(BuildGraphNode.self, from: Data(formula.utf8))
//        try integrate(buildGraphOutput: buildGraphDescription)
    }

    // Follows 'outputNode' backwards through its dependencies to reconstruct a live processing graph that mirrors the structure of the build graph description.
    // Returns the node corresponding to 'outputNode' in the live processing graph.
    // Note that there is one conceptual formula for each output file, but the graph may reuse nodes for shared dependencies.
    func reverseEngineerFormula(outputNode: StaticFileNode) throws -> BuildGraphNode {
        var cache: [ObjectID: BuildGraphNode] = [:]
        return try reverseEngineerNode(liveNode: outputNode, cache: &cache)
    }

    /// Recursively reconstructs a `BuildGraphNode` from the live node/wire graph.
    /// `cache` stores already-reconstructed nodes so shared dependencies are visited once
    /// and cycles (which should not exist in a valid build graph) are handled safely.
    private func reverseEngineerNode(liveNode: NodeType,
                                     cache: inout [ObjectID: BuildGraphNode]) throws -> BuildGraphNode {
        let database = nodeContext.processingCycle.database

        guard let nodeID = liveNode.nodeContext.nodeID else {
            throw BuildGraphError.unknownInputPortNameReference
        }

        // Return cached result if this node has already been reconstructed
        if let cached = cache[nodeID] { return cached }

        // Store a placeholder immediately to break any accidental cycles
        let nodeName = liveNode.nodeContext.name ?? "?"
        cache[nodeID] = BuildGraphNode(name: nodeName, kind: .inputFile)

        // Gather all incoming wires and group them by destination port index
        let incomingWires = try database.selectWires(goingToNodeID: nodeID)

        var wiresByDestinationPort: [UInt8: [BuildGraphInputWire]] = [:]
        for wire in incomingWires {
            guard let sourceRawNode = try? database.selectNodeByID(wire.fromNodeID),
                  let sourceNode = try? nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: sourceRawNode)
            else { continue }

            // Recursively reconstruct the source node
            let sourceBuildGraphNode = try reverseEngineerNode(liveNode: sourceNode, cache: &cache)

            // Resolve the source's output port name from its descriptor
            let fromPortName = sourceNode.descriptor.outputs
                .first(where: { $0.index == wire.fromPort })?.name ?? "output"

            wiresByDestinationPort[wire.toPort, default: []]
                .append(BuildGraphInputWire(from: sourceBuildGraphNode, fromPort: fromPortName))
        }

        // Build the ordered input-port list, skipping ports with no wires
        let inputPorts: [BuildGraphInputPort] = liveNode.descriptor.inputs.compactMap { port in
            let wires = wiresByDestinationPort[port.index] ?? []
            guard !wires.isEmpty else { return nil }
            return BuildGraphInputPort(name: port.name, inputWires: wires)
        }

        // Determine the BuildGraphNodeKind for this node
        let nodeKind = try reverseEngineerNodeKind(for: liveNode, inputPorts: inputPorts)
        let result = BuildGraphNode(name: nodeName, kind: nodeKind)
        cache[nodeID] = result
        return result
    }

    /// Maps a live NodeType to the appropriate BuildGraphNodeKind.
    private func reverseEngineerNodeKind(for liveNode: NodeType,
                                         inputPorts: [BuildGraphInputPort]) throws -> BuildGraphNodeKind {
        switch type(of: liveNode).kind {
        case ClangPreprocessorTool.kind:
            return .tool(kind: .preprocessor, inputPorts: inputPorts)
        case ClangCompilerTool.kind:
            return .tool(kind: .compiler, inputPorts: inputPorts)
        case ClangLinkerTool.kind:
            return .tool(kind: .linker, inputPorts: inputPorts)
        case StaticFileNode.kind:
            return try reverseEngineerStaticFileNodeKind(for: liveNode as! StaticFileNode,
                                                         inputPorts: inputPorts)
        default:
            return .inputFile
        }
    }

    /// Distinguishes whether a StaticFileNode is an input file, a configuration node, or
    /// an output file by walking up its parent chain until a well-known root folder is found.
    private func reverseEngineerStaticFileNodeKind(for node: StaticFileNode,
                                                   inputPorts: [BuildGraphInputPort]) throws -> BuildGraphNodeKind {
        let database = nodeContext.processingCycle.database

        guard let nodeID = node.nodeContext.nodeID,
              var currentRaw = try database.selectNodeByID(nodeID)
        else { return .inputFile }

        while let parentID = currentRaw.parentNodeID {
            guard let parentRaw = try database.selectNodeByID(parentID) else { break }

            switch parentRaw.name {
            case "outputFileSystem":
                return .outputFile(inputPorts: inputPorts)

            case "inputFileSystem":
                return .inputFile

            default:
                // Not a recognised root — keep walking up
                currentRaw = parentRaw
            }
        }

        return .inputFile
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

                            try configurationNode.writeToOutputPort(StaticFileNode.outputPort,
                                                                    value: .value(.dataObjectHash(configuration.intern()),
                                                                                  metadata: FileMetadata(name: "configuration")))
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
                throw NodeError.missingInput
            case .value(let payload, _):
                return try BuildGraphNode.fromJSON(payload.expectDataObjectHash().resolveAsString())
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
