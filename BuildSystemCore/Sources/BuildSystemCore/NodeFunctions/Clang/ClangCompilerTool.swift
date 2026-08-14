// ClangCompilerTool.swift
// build_system
//
// Clang compiler stage: compiles a preprocessed .p file into a .o object file.

import Foundation

// MARK: - Configuration

struct ClangCompilerToolConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    /// C++ language standard, e.g. `"c++17"` or `"c++20"`.
    /// Defaults to `"c++17"` for C++ source files when not specified.
    let std: String?

    init(properties: [String: String]) {
        toolDescriptor = .init(properties: properties)
        arguments = []
        environment = [:]
        std = properties["std"]
    }
}

// MARK: - Node

public struct ClangCompilerTool: NodeFunction {
    public static let kind: UInt = 19

    // MARK: Ports

    static let configuration = "configuration"
    static let input = "input"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    var embeddedNode: Node

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    static let descriptor = NodeFunctionDescriptor(
        inputPorts: [.required(configuration), .required(input)],
        outputPorts: [output, errorLog, infoLog]
    )

    // MARK: Processing

    struct ClangCompilerToolInputs {
        let configuration: ClangCompilerToolConfiguration
        let inputSourceFile: FileNameAndContent

        init(input: ProcessInput) throws {
            let configurationString = try input.inputValues[ClangCompilerTool.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = .init(properties: [String: String](plainText: configurationString))

            let input = input.inputValues[ClangCompilerTool.input]!.first!
            inputSourceFile = .init(filePath: input.key, hash: try input.value.expectValue())
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
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    func process(inputs: ClangCompilerToolInputs) throws -> ClangCompilerToolOutputs {

        let outputFilename = inputs.inputSourceFile.filePath + ".o"

        let language = ClangPreprocessorTool.language(for: inputs.inputSourceFile.filePath)
        let effectiveStd = inputs.configuration.std ?? (language == "c++" ? "c++17" : nil)

        var arguments = [String]()
        arguments.append("-x");      arguments.append(language)
        arguments.append("-c")
        if let std = effectiveStd {
            arguments.append("-std=\(std)")
        }
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
            inputFiles: [.init(filePath: inputs.inputSourceFile.filePath, hash: inputs.inputSourceFile.hash)],
            expectedOutputFileNames: [outputFilename],
            output: .init(logError: { error in
                              errorOutput += error
                              errorOutput += "\n"
//                              print(error)
                          },
                          logMessage: { message in
                              infoOutput += message
                              infoOutput += "\n"
//                              print(message)
                          },
                          write: { _, data in
                              output.append(contentsOf: data)
                          })).exitCode

        let errorOutputInterned = try errorOutput.intern()

        // TODO: error messages should be interned also in .noValue enum
        return .init(output: (exitCode == 0) ? .value(try output.intern()) : .noValue(reason: .error(messageDataObjectHash: errorOutputInterned)),
                     errorLog: .value(errorOutputInterned),
                     infoLog: .value(try infoOutput.intern()))
    }
}
