// ClangCompilerTool.swift
// build_system
//
// Clang compiler stage: compiles a preprocessed .p file into a .o object file.

import Foundation

// MARK: - Configuration

struct ClangCompilerToolConfiguration: PolySerializable {
    static let kind: UInt = 16

    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]

    init(toolDescriptor: ToolDescriptor, arguments: [String], environment: [String: String]) throws {
        self.toolDescriptor = toolDescriptor
        self.arguments = arguments
        self.environment = environment
    }
}

protocol NodeInputReader {
    func readAllValuesFromInputPort(_ inputPort: String) throws -> [String: NodeValue]
}

protocol NodeOutputWriter {
    func writeToOutputPort(_ outputPort: String, value: NodeValue) throws
}

// MARK: - Node

struct ClangCompilerTool: NodeFunction {
    static let kind: UInt = 19

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
    static let input = "input"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [configuration, input],
                                            staticOutputPorts: [output, errorLog, infoLog])

    // MARK: Processing

    struct ClangCompilerToolInputs {
        let configuration: ClangCompilerToolConfiguration
        let inputSourceFileContent: [UInt8]
        let inputSourceFileName: String

        init(nodeInputReader: NodeInputReader) throws {
            let configurationString = try nodeInputReader.readAllValuesFromInputPort(ClangCompilerTool.configuration).first!.value.expectValue().resolveAsString()
            configuration = try PolyFactory.decodeAndCast(encodedJSON: configurationString)

            let input = try nodeInputReader.readAllValuesFromInputPort(ClangCompilerTool.input).first!
            inputSourceFileContent = try input.value.expectValue().resolve()
            inputSourceFileName = input.key
        }
    }

    struct ClangCompilerToolOutputs {
        let output: NodeValue
        let errorLog: NodeValue
        let infoLog: NodeValue

        func write(nodeOutputWriter: NodeOutputWriter) throws {
            try nodeOutputWriter.writeToOutputPort(ClangCompilerTool.output, value: output)
            try nodeOutputWriter.writeToOutputPort(ClangCompilerTool.errorLog, value: errorLog)
            try nodeOutputWriter.writeToOutputPort(ClangCompilerTool.infoLog, value: infoLog)
        }
    }

    func process() throws {
        let inputs = try ClangCompilerToolInputs(nodeInputReader: self)
        let outputs = try process(inputs: inputs)
        try outputs.write(nodeOutputWriter: self)
    }

    func process(inputs: ClangCompilerToolInputs) throws -> ClangCompilerToolOutputs {

        let outputFilename = inputs.inputSourceFileName + ".o"

        var arguments = [String]()
        arguments.append("-x");      arguments.append("c")
        arguments.append("-c")
        arguments.append(inputs.inputSourceFileName)
        arguments.append("-o");      arguments.append(outputFilename)
        arguments.append("-target"); arguments.append("arm64-apple-macos14.0")
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var output: [UInt8] = []
        var errorOutput = ""
        var infoOutput = ""

        let exitCode = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: [.init(filePath: inputs.inputSourceFileName, content: inputs.inputSourceFileContent)],
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

        return .init(output: (exitCode == 0) ? .value(output.intern()) : .noValue(reason: .error(message: "Compiler exited with exitcode \(exitCode)")),
                     errorLog: .value(errorOutput.intern()),
                     infoLog: .value(infoOutput.intern()))
    }
}
