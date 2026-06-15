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

// MARK: - Node

struct ClangCompilerTool: NodeFunction {
    static let kind: UInt = 19

    enum CodingKeys: CodingKey {
    }

    // MARK: Ports

    static let configuration = "configuration"
    static let input = "input"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [configuration, input],
                                            outputPorts: [output, errorLog, infoLog])

    // MARK: Processing

    struct ClangCompilerToolInputs {
        let configuration: ClangCompilerToolConfiguration
        let inputSourceFile: FileNameAndContent

        init(input: ProcessInput) throws {
            let configurationString = try input.inputValues[ClangCompilerTool.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = try PolyFactory.decodeAndCast(encodedJSON: configurationString)

            let input = input.inputValues[ClangCompilerTool.input]!.first!
            inputSourceFile = .init(filePath: input.key, content: try input.value.expectValue().resolve())
        }
    }

    struct ClangCompilerToolOutputs {
        let output: NodeValue
        let errorLog: NodeValue
        let infoLog: NodeValue

        func asProcessOutput() throws -> ProcessOutput {
            .init(outputValues: [ClangCompilerTool.output: output,
                                 ClangCompilerTool.errorLog: errorLog,
                                 ClangCompilerTool.infoLog: infoLog],
                  inputWireExpectations: [:])
        }
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        let inputs = try ClangCompilerToolInputs(input: input)
        return try process(inputs: inputs).asProcessOutput()
    }

    func process(inputs: ClangCompilerToolInputs) throws -> ClangCompilerToolOutputs {

        let outputFilename = inputs.inputSourceFile.filePath + ".o"

        var arguments = [String]()
        arguments.append("-x");      arguments.append("c")
        arguments.append("-c")
        arguments.append(inputs.inputSourceFile.filePath)
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
            inputFiles: [.init(filePath: inputs.inputSourceFile.filePath, content: inputs.inputSourceFile.content)],
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
