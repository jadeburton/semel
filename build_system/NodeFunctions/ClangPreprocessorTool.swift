// ClangPreprocessorTool.swift
// build_system
//
// Clang preprocessor stage: runs `clang -E` on a .c file and its headers,
// producing a preprocessed .p file ready for the compiler stage.

import Foundation

// MARK: - Configuration

struct ClangPreprocessorToolConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]

    init(properties: [String: String]) {
        toolDescriptor = .init(name: properties["toolDescriptor.name"] ?? "clang",
                               version: properties["toolDescriptor.version"] ?? "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                               platform: properties["toolDescriptor.platform"] ?? "macOS",
                               architecture: properties["toolDescriptor.architecture"] ?? "arm64",
                               recursiveHash: properties["toolDescriptor.recursiveHash"] ?? "")
        arguments = []
        environment = [:]
    }

    func asDictionary() -> [String: String] {
        ["toolDescriptor.name": toolDescriptor.name,
         "toolDescriptor.version": toolDescriptor.version,
         "toolDescriptor.platform": toolDescriptor.platform,
         "toolDescriptor.architecture": toolDescriptor.architecture,
         "toolDescriptor.recursiveHash": toolDescriptor.recursiveHash ?? ""]
    }
}

// MARK: - Node

struct ClangPreprocessorTool: NodeFunction {
    static let kind: UInt = 17

    enum CodingKeys: CodingKey {
    }

    var embeddedNode: Node?

    var properties: [String : String] {
        [:]
    }

    init(properties: [String: String]) {
    }

    // MARK: Ports

    static let configuration = "configuration"
    static let sourceFileInput = "input"
    static let includeFileLists = "includeFileLists"
    static let headerInputFiles = "headerInputFiles"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [configuration, sourceFileInput],
                                            outputPorts: [output, errorLog, infoLog],
                                            dynamicInputPorts: [includeFileLists, headerInputFiles])

    // MARK: Processing

    struct ClangPreprocessorToolInputs {
        let configuration: ClangPreprocessorToolConfiguration
        let inputSourceFile: FileNameAndContent
        let headerFiles: [FileNameAndContent]
        let includePathLists: [String: [String]]

        init(processInput: ProcessInput) throws {
            let configurationString = try processInput.inputValues[ClangCompilerTool.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = .init(properties: [String: String](plainText: configurationString))

            let input = processInput.inputValues[ClangPreprocessorTool.sourceFileInput]!.first!
            inputSourceFile = .init(filePath: input.key, content: try input.value.expectValue().resolve())

            let headerInputFiles = processInput.inputValues[ClangPreprocessorTool.headerInputFiles]!

            var headerFiles: [FileNameAndContent] = []

            for (headerFileName, nodeValue) in headerInputFiles {
                headerFiles.append(.init(filePath: headerFileName, content: try nodeValue.expectValue().resolve()))
            }

            self.headerFiles = headerFiles

            includePathLists = try Dictionary(uniqueKeysWithValues: processInput.inputValues[ClangPreprocessorTool.includeFileLists]!.map { includeFilesValue in
                let wireName = includeFilesValue.key
                let list = try includeFilesValue.value
                    .expectValue()
                    .resolveAsString()
                    .split(separator: "\n")
                    .map { String($0) }
                return (wireName, list)
            })
        }
    }

    struct ClangPreprocessorToolOutputs {
        let output: NodeValue
        let errorLog: NodeValue
        let infoLog: NodeValue

        let headerInputFilesWireExpectations: [String: String] // TODO: graph object, starting from the name of the output on the rootmost Node
        let includeFileListWireExpections: [String: String] // TODO: graph object, starting from the name of the output on the rootmost Node

        func asProcessOutput() -> ProcessOutput {
            return .init(outputValues: [ClangPreprocessorTool.output: output,
                                 ClangPreprocessorTool.errorLog: errorLog,
                                 ClangPreprocessorTool.infoLog: infoLog],
                  inputWireExpectations: [ClangPreprocessorTool.headerInputFiles: headerInputFilesWireExpectations,
                                          ClangPreprocessorTool.includeFileLists: includeFileListWireExpections])
        }
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        let inputs = try ClangPreprocessorToolInputs(processInput: input)
        return try process(inputs: inputs).asProcessOutput()
    }

    private func runPreprocessor(inputs: ClangPreprocessorToolInputs,
                                 headerInputFilesWireExpectations: [String: String],
                                 includeFileListWireExpections: [String: String]) throws -> ClangPreprocessorToolOutputs {

        let outputFilename = inputs.inputSourceFile.filePath + ".p"

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
        arguments.append(inputs.inputSourceFile.filePath)
        arguments.append("-o"); arguments.append(outputFilename)
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var inputFiles: [FileNameAndContent] = [.init(filePath: inputs.inputSourceFile.filePath, content: inputs.inputSourceFile.content)]

        inputFiles.append(contentsOf: inputs.headerFiles)

        var output: [UInt8] = []
        var errorOutput = ""
        var infoOutput = ""

        let exitCode = try tool.execute(arguments: arguments,
                                        environment: inputs.configuration.environment,
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

        return .init(output: (exitCode == 0) ? .value(output.intern()) : .noValue(reason: .error(message: "Preprocessor exited with exitcode \(exitCode)")),
                     errorLog: .value(errorOutput.intern()),
                     infoLog: .value(infoOutput.intern()),
                     headerInputFilesWireExpectations: headerInputFilesWireExpectations,
                     includeFileListWireExpections: includeFileListWireExpections)
    }

    func process(inputs: ClangPreprocessorToolInputs) throws -> ClangPreprocessorToolOutputs {

        var headerInputFilesWireExpectations = [String: String]()

        let setOfIncludeFiles: Set<String> = Set(inputs.includePathLists.flatMap { (_, list) in list })

        let aggregatedIncludePathList: [String] = .init(setOfIncludeFiles)

        for includePath in aggregatedIncludePathList {
            headerInputFilesWireExpectations[includePath] = "StaticFile(path: '\(includePath)').output"
        }

        var includeFileListWireExpections = [String: String]()

        for sourcePath in (aggregatedIncludePathList + [inputs.inputSourceFile.filePath]) {
            includeFileListWireExpections[sourcePath] = "IncludeFinder(sourceFile <- ['\(sourcePath)': StaticFile(path: '\(sourcePath)').output]).includePathList"
        }

        // There must be one IncludeFinder attached to the .c file.

        if inputs.includePathLists[inputs.inputSourceFile.filePath] == nil {
            let error = NodeValue.noValue(reason: .error(message: "Still resolving include files"))
            return .init(output: error,
                         errorLog: error,
                         infoLog: error,
                         headerInputFilesWireExpectations: headerInputFilesWireExpectations,
                         includeFileListWireExpections: includeFileListWireExpections)
        }

        // do we have input wires for each of the Headers mentioned in the aggregated Include list?
        //    no -> set our output to Error but set our Expected Header File Wires to equal the Include List, so that new wires will be connected
        //          that will cause us to be scheduled for processing a second time. and connecting a new wire instantly causes all downstream
        //          nodes' outputs to go to Pending, including us.
        //    yes -> proceed to running the preprocessor
        guard inputs.headerFiles.count == aggregatedIncludePathList.count else {
            let error = NodeValue.noValue(reason: .error(message: "Still resolving include files"))
            return .init(output: error,
                         errorLog: error,
                         infoLog: error,
                         headerInputFilesWireExpectations: headerInputFilesWireExpectations,
                         includeFileListWireExpections: includeFileListWireExpections)
        }

        return try runPreprocessor(inputs: inputs,
                                   headerInputFilesWireExpectations: headerInputFilesWireExpectations,
                                   includeFileListWireExpections: includeFileListWireExpections)
    }
}
