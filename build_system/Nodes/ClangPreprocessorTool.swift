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

struct ClangPreprocessorTool: NodeFunction {
    static let kind: UInt = 17

    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {}

    init() {}

    init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
    }

    // MARK: Ports

    static let configuration = "configuration"
    static let sourceFileInput = "input"
    static let includeFiles = "includeFiles"

    // ISSUE: if there is a missing header file but it is added, we don't get notified.
    // we need to monitor for all new header files - but only if we are in an error state
    static let headerInputFiles = "headerInputFiles"

    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    var descriptor: NodeFunctionDescriptor {
        .init(staticInputPorts: [Self.configuration, Self.sourceFileInput, Self.includeFiles, Self.headerInputFiles],
              staticOutputPorts: [Self.output, Self.errorLog, Self.infoLog])
    }

    // MARK: Processing

    func process() throws {

        let configuration: ClangPreprocessorToolConfiguration = try readConfiguration(fromInputPort: Self.configuration)
        let primarySourceFile = try readOneValueFromInputPort(Self.sourceFileInput)

        // MARK: Include-finder helpers
/*
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
                parentNodeID: nodeContext.processingCycle.rootNode.nodeID) as! IncludeFinder
        }*/

/*        func ensureSourceOrHeaderNodeHasIncludeFinderAttached(_ sourceNodeID: ObjectID) throws {
            let includeFinder = try createOrFindIncludeFinderAttachedToNode(sourceNodeID: sourceNodeID)

            let sourceNode = try nodeContext.processingCycle.node(nodeID: sourceNodeID) as StaticFileNode
            try nodeContext.processingCycle.connectWire(fromNodeID: sourceNode.nodeID,
                                                        fromSymbolID: StaticFileNode.outputPort.asSymbolID(),
                                                        toNodeID: includeFinder.nodeID,
                                                        toSymbolID: IncludeFinder.sourceFileInputPort.asSymbolID())
            try nodeContext.processingCycle.connectWire(fromNodeID: includeFinder.nodeID,
                                                        fromSymbolID: IncludeFinder.includePathListOutputPort.asSymbolID(),
                                                        toNodeID: self.nodeID,
                                                        toSymbolID: Self.includeFiles.asSymbolID())
        }
*/
        func ensureIncludeFileIsAttached(_ includePath: String) throws {
            guard let staticFileNode = try nodeContext.processingCycle.rootNode.inputFileSystem.childPoly(path: includePath,
                                                                                                          kind: StaticFileNode.kind,
                                                                                                          createIfNotExist: true) as? StaticFileNode else {

                throw NodeError.other(message: "Could not find a StaticFileNode that corresponds to \(includePath)")
            }

            try nodeContext.processingCycle.connectWire(fromNodeID: staticFileNode.nodeID,
                                                        fromSymbolID: StaticFileNode.outputPort.asSymbolID(),
                                                        toNodeID: self.nodeID,
                                                        toSymbolID: Self.headerInputFiles.asSymbolID(),
                                                        name: includePath.asSymbolID())
        }

        func removeIncludeFileWiresNotInList(_ allowedIncludePaths: Set<String>) throws {
            let db = nodeContext.processingCycle.database
            let allWiresToNode = try db.selectWires(goingToNodeID: self.nodeID)

            for wire in allWiresToNode {
                #warning("TODO")
/*                guard wire.toPort == Self.headerInputFiles.index else { continue }

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
                }*/
            }
        }

        // MARK: Main switch

        //try ensureSourceOrHeaderNodeHasIncludeFinderAttached(primarySourceFile.originNodeID)

        let bytes = try primarySourceFile.1.expectValue().resolve()
        var output: [UInt8] = []

        let inputFilename  = "input.c"
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
        let includeFilesValues = try readAllValuesFromInputPort(Self.includeFiles)

        let setOfIncludeFiles: Set<String> = Set(try includeFilesValues.flatMap { includeFilesValue -> [String] in
            try includeFilesValue.value.expectValue().resolveAsString().split(separator: "\n").map(String.init)
        })

        for includeFilePath in setOfIncludeFiles {
            try ensureIncludeFileIsAttached(includeFilePath)
        }
        try removeIncludeFileWiresNotInList(setOfIncludeFiles)

        let headerInputFilesValues = try readAllValuesFromInputPort(Self.headerInputFiles)
        for headerInputFilesValue in headerInputFilesValues {
            //try ensureSourceOrHeaderNodeHasIncludeFinderAttached(headerInputFilesValue.originNodeID)
        }

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: configuration.toolDescriptor)

        var inputFiles: [FileNameAndContent] = [.init(filePath: inputFilename, content: bytes)]

        inputFiles.append(contentsOf: try headerInputFilesValues.compactMap { nodeValue -> FileNameAndContent? in
            .init(filePath: nodeValue.key, content: try nodeValue.value.expectValue().resolve())
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

        try writeToOutputPort(Self.errorLog, value: .value(errorOutput.intern()))
        try writeToOutputPort(Self.infoLog, value: .value(infoOutput.intern()))

        if exitCode == 0 {
            try writeToOutputPort(Self.output, value: .value(output.intern()))
        } else {
            try writeToOutputPort(Self.output, value: .noValue(reason: .error(message: "Nonzero exit code")))
        }
    }
}
