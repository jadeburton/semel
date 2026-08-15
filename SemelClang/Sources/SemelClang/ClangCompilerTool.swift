// ClangCompilerTool.swift
// build_system
//
// Clang compiler stage: compiles a preprocessed .p file into a .o object file.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

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

    public var embeddedNode: Node

    public init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    public static let descriptor = NodeFunctionDescriptor(
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

    public func process(input: ProcessInput) throws -> ProcessOutput {
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

        let result = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: [.init(filePath: inputs.inputSourceFile.filePath, hash: inputs.inputSourceFile.hash)],
            expectedOutputFileNames: [outputFilename])

        return .init(output: try result.asOutputNodeValue(),
                     errorLog: .value(try result.errorOutput.intern()),
                     infoLog: .value(try result.infoOutput.intern()))
    }
}


