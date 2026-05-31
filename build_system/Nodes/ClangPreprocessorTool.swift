// ClangPreprocessorTool.swift
// build_system
//
// Clang preprocessor stage: runs `clang -E` on a .c file and its headers,
// producing a preprocessed .p file ready for the compiler stage.

import Foundation

// MARK: - Configuration

struct ClangPreprocessorToolConfiguration: PolySerializable {
    static let kind: UInt = 11

    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]

    init(toolDescriptor: ToolDescriptor, arguments: [String], environment: [String: String]) throws {
        self.toolDescriptor = toolDescriptor
        self.arguments = arguments
        self.environment = environment
    }
}

// MARK: - Node

final class ClangPreprocessorTool: NodeType {
    static let kind: UInt = 17

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

    static let configuration = NodeKindDescriptor.InputPort(index: 0,
                                                            name: "configuration",
                                                            kind: .value(dataType: .utf8Text),
                                                            maximumConnections: 1,
                                                            minimumConnections: 1,
                                                            cascadingDelete: false)

    static let sourceFileInput = NodeKindDescriptor.InputPort(index: 1,
                                                              name: "input",
                                                              kind: .value(dataType: .utf8Text),
                                                              maximumConnections: 1,
                                                              minimumConnections: 1,
                                                              cascadingDelete: false)

    static let includeFiles = NodeKindDescriptor.InputPort(index: 2,
                                                           name: "includeFiles",
                                                           kind: .value(dataType: .utf8Text),
                                                           maximumConnections: nil,
                                                           minimumConnections: 0,
                                                           cascadingDelete: false)

    // ISSUE: if there is a missing header file but it is added, we don't get notified.
    // we need to monitor for all new header files - but only if we are in an error state
    static let headerInputFiles = NodeKindDescriptor.InputPort(index: 3,
                                                               name: "headerInputFiles",
                                                               kind: .value(dataType: .utf8Text),
                                                               maximumConnections: nil,
                                                               minimumConnections: 0,
                                                               cascadingDelete: false)

    static let output = NodeKindDescriptor.OutputPort(index: 2,
                                                      name: "output",
                                                      kind: .value(dataType: .utf8Text))

    static let errorLog = NodeKindDescriptor.OutputPort(index: 0,
                                                        name: "errorLog",
                                                        kind: .value(dataType: .utf8Text))

    static let infoLog = NodeKindDescriptor.OutputPort(index: 1,
                                                       name: "infoLog",
                                                       kind: .value(dataType: .utf8Text))

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind,
              inputs: [Self.configuration, Self.sourceFileInput, Self.includeFiles, Self.headerInputFiles],
              outputs: [Self.output, Self.errorLog, Self.infoLog])
    }

    // MARK: Processing

    func process() throws {

        guard let configuration: ClangPreprocessorToolConfiguration = try readConfiguration(fromInputPort: Self.configuration) else {
            throw NodeError.missingInputs
        }

        guard let primarySourceFile = try readOneValueFromInputPort(Self.sourceFileInput) else {
            throw NodeError.missingInputs
        }

        // MARK: Include-finder helpers

        func createOrFindIncludeFinderAttachedToNode(sourceNodeID: ObjectID) throws -> IncludeFinder {
            let db = nodeContext.processingCycle.database
            let allWiresFromSourceNode = try db.selectWires(comingFromNodeID: sourceNodeID)

            for wire in allWiresFromSourceNode {
                let toNode = try nodeContext.processingCycle.wrapRawNodePoly(
                    nodeRaw: try wire.toNodeID.loadNode(from: db)) as? IncludeFinder
                if let toNode { return toNode }
            }

            return try nodeContext.processingCycle.makeNodePoly(
                kind: IncludeFinder.kind,
                name: "includeFinder",
                parentNodeID: nodeContext.processingCycle.rootNode.nodeContext.nodeID!) as! IncludeFinder
        }

        func ensureSourceOrHeaderNodeHasIncludeFinderAttached(_ sourceNodeID: ObjectID) throws {
            let includeFinder = try createOrFindIncludeFinderAttachedToNode(sourceNodeID: sourceNodeID)

            let sourceNode = try nodeContext.processingCycle.node(nodeID: sourceNodeID) as StaticFileNode
            try nodeContext.processingCycle.connectWire(fromNode: sourceNode,
                                                        fromPort: StaticFileNode.outputPort,
                                                        toNode: includeFinder,
                                                        toPort: IncludeFinder.sourceFileInputPort)
            try nodeContext.processingCycle.connectWire(fromNode: includeFinder,
                                                        fromPort: IncludeFinder.includePathListOutputPort,
                                                        toNode: self,
                                                        toPort: Self.includeFiles)
        }

        func ensureIncludeFileIsAttached(_ includePath: String) throws {
            guard let staticFileNode = try nodeContext.processingCycle.rootNode.inputFileSystem.childPoly(path: includePath,
                                                                                                          kind: StaticFileNode.kind,
                                                                                                          createIfNotExist: true) as? StaticFileNode else {

                throw NodeError.other(message: "Could not find a StaticFileNode that corresponds to \(includePath)")
            }

            try nodeContext.processingCycle.connectWire(fromNode: staticFileNode,
                                                        fromPort: StaticFileNode.outputPort,
                                                        toNode: self,
                                                        toPort: Self.headerInputFiles)
        }

        func removeIncludeFileWiresNotInList(_ allowedIncludePaths: Set<String>) throws {
            let db = nodeContext.processingCycle.database
            let allWiresToNode = try db.selectWires(goingToNodeID: nodeContext.nodeID!)

            for wire in allWiresToNode {
                guard wire.toPort == Self.headerInputFiles.index else { continue }

                let fromRaw = try wire.fromNodeID.loadNode(from: db)
                let fromNode = try nodeContext.processingCycle.wrapRawNodePoly(nodeRaw: fromRaw)

                if let staticFile = fromNode as? StaticFileNode {
                    let fullPath = try staticFile.buildFullPathName()
                    if !allowedIncludePaths.contains(fullPath) {
                        _ = try nodeContext.processingCycle.deleteWire(fromNode: staticFile,
                                                                       fromPort: StaticFileNode.outputPort,
                                                                       toNode: self,
                                                                       toPort: Self.headerInputFiles)
                    }
                }
            }
        }

        // MARK: Main switch

        switch primarySourceFile.kind {

        case .noValue:
            throw NodeError.missingInputs

        case .value(let payload, let metadata):

            try ensureSourceOrHeaderNodeHasIncludeFinderAttached(primarySourceFile.originNodeID)

            let bytes = try payload.expectDataObjectHash().resolve()
            var output: [UInt8] = []

            let inputFilename  = metadata ?? "input.c"
            let outputFilename = inputFilename + ".p"

            var arguments = [String]()

            // Preprocess only.
            arguments.append("-E")
            arguments.append("-x"); arguments.append("c")
            arguments.append("-I"); arguments.append(".")
            // TODO: standard includes should come from a versioned, hashed SDK snapshot.
            arguments.append("-I")
            arguments.append("/Applications/Xcode_26_2.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include")
            arguments.append("-nostdinc")
            arguments.append("-target"); arguments.append("arm64-apple-macos14.0")
            arguments.append(inputFilename)
            arguments.append("-o"); arguments.append(outputFilename)
            arguments.append(contentsOf: configuration.arguments)

            // Wire up include files discovered by IncludeFinder nodes.
            let includeFilesValues: [NodeValueAndWire] = try readAllValuesFromInputPort(Self.includeFiles)

            let setOfIncludeFiles: Set<String> = Set(try includeFilesValues.flatMap { includeFilesValue -> [String] in
                switch includeFilesValue.kind {
                case .value(let payload, _):
                    return try payload.expectDataObjectHash().resolveAsString()
                        .split(separator: "\n").map(String.init)
                case .noValue:
                    throw NodeError.missingInputs
                }
            })

            for includeFilePath in setOfIncludeFiles {
                try ensureIncludeFileIsAttached(includeFilePath)
            }
            try removeIncludeFileWiresNotInList(setOfIncludeFiles)

            let headerInputFilesValues: [NodeValueAndWire] = try readAllValuesFromInputPort(Self.headerInputFiles)
            for headerInputFilesValue in headerInputFilesValues {
                try ensureSourceOrHeaderNodeHasIncludeFinderAttached(headerInputFilesValue.originNodeID)
            }

            let tool = try ToolExecutorRegistry.instance.tool(descriptor: configuration.toolDescriptor)

            var inputFiles: [FileNameAndContent] = [.init(filePath: inputFilename, content: bytes)]

            inputFiles.append(contentsOf: try headerInputFilesValues.compactMap { nodeValue -> FileNameAndContent? in
                switch nodeValue.kind {
                case .value(let payload, let metadata):
                    let filePath: String
                    if let staticFileNode: StaticFileNode = try? nodeContext.processingCycle.node(nodeID: nodeValue.originNodeID) {
                        filePath = (try? staticFileNode.buildFullPathName()) ?? metadata!
                    } else {
                        filePath = metadata!
                    }
                    return .init(filePath: filePath, content: try payload.expectDataObjectHash().resolve())
                case .noValue:
                    throw NodeError.missingInputs
                }
            })

            var errorOutput = ""
            var infoOutput = ""

            let exitCode = try tool.execute(arguments: arguments,
                                            environment: configuration.environment,
                                            inputFiles: inputFiles,
                                            expectedOutputFileNames: [outputFilename],
                                            output: .init(logError: { error in
                                                              errorOutput += error
                                                              errorOutput += "\n"
                                                              print(error)
                                                          },
                                                          logMessage: { message in
                                                              infoOutput += message
                                                              infoOutput += "\n"
                                                              print(message)
                                                          },
                                                          write: { _, data in
                                                              output.append(contentsOf: data)
                                                          }))

            try writeToOutputPort(Self.errorLog, value: .value(.dataObjectHash(errorOutput.intern()), metadata: nil))
            try writeToOutputPort(Self.infoLog, value: .value(.dataObjectHash(infoOutput.intern()), metadata: nil))

            if exitCode == 0 {
                try writeToOutputPort(Self.output, value: .value(.dataObjectHash(output.intern()),
                                                                 metadata: outputFilename))
            } else {
                try writeToOutputPort(Self.output, value: .noValue(reason: .error(message: "Nonzero exit code")))
            }
        }
    }
}
