// ClangLinkerTool.swift
// build_system
//
// Clang linker stage: links one or more .o object files (and optional .dylib
// libraries) into a final output binary.

import Foundation

// MARK: - Configuration

// TODO: multiple partial config objects can be bound to an Input port, then they will be merged automatically.
struct ClangLinkerToolConfiguration: PolySerializable {
    static let kind: UInt = 12

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

struct ClangLinkerTool: NodeFunction {
    static let kind: UInt = 18

    var nodeContext: NodeContext!

    enum CodingKeys: CodingKey {}

    init() {
    }

    init(from decoder: Decoder) throws {
        let _ = try decoder.container(keyedBy: CodingKeys.self)
    }

    func encode(to encoder: Encoder) throws {
        var _ = encoder.container(keyedBy: CodingKeys.self)
    }

    // MARK: Ports

    static let configuration = "configuration"

    // TODO: rename to "objectFiles"
    static let input = "input"

    static let libraries = "libraries"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [configuration, input, libraries],
                                            staticOutputPorts: [output, errorLog, infoLog])

    // MARK: Processing

    func process() throws {

        let configuration: ClangLinkerToolConfiguration = try readConfiguration(fromInputPort: Self.configuration)

        let inputValues = try readAllValuesFromInputPort(Self.input)
        let libraryValues = try readAllValuesFromInputPort(Self.libraries)

        // Separate .dylib library files from .o object files.
        var libraryFiles: [FileNameAndContent] = []

        for (libraryName, nodeValue) in libraryValues {
            libraryFiles.append(.init(filePath: libraryName, content: try nodeValue.expectValue().resolve()))
        }

        var objectFiles: [FileNameAndContent] = []

        for (objectFileName, nodeValue) in inputValues {
            objectFiles.append(.init(filePath: objectFileName, content: try nodeValue.expectValue().resolve()))
        }

        guard !objectFiles.isEmpty else {
            throw NodeError.missingInputs
        }

        var output: [UInt8] = []
        var arguments = [String]()

        arguments.append(contentsOf: configuration.arguments)
        arguments.append("-target"); arguments.append("arm64-apple-macos14.0")
        arguments.append("-L"); arguments.append(".")
        // TODO: lock down SDK version and hash for full hermeticity.
        arguments.append("-L")
        arguments.append("-dynamiclib")
        arguments.append("/Applications/Xcode_26_2.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib")
        arguments.append("-lSystem")
        arguments.append("-nostdlib")

        for objectFile in objectFiles   { arguments.append(objectFile.filePath)  }
        for libraryFile in libraryFiles { arguments.append(libraryFile.filePath) }

        arguments.append("-o"); arguments.append("output.dylib")
        arguments.append(contentsOf: configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: configuration.toolDescriptor)

        var inputFiles: [FileNameAndContent] = []
        inputFiles.append(contentsOf: libraryFiles)
        inputFiles.append(contentsOf: objectFiles)

        var errorOutput = ""
        var infoOutput = ""

        let exitCode = try tool.execute(
            arguments: arguments,
            environment: configuration.environment,
            inputFiles: inputFiles,
            expectedOutputFileNames: ["output.dylib"],
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
            try writeToOutputPort(Self.output, value: .noValue(reason: .error(message: "Linker exited with nonzero status")))
        }
    }
}
