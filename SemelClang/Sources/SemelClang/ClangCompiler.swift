// ClangCompiler.swift
// semel
//
// Clang compiler stage: compiles a preprocessed .p file into a .o object file.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct ClangCompilerConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    /// Language standard, e.g. `"c++20"` or `"c17"`. Required for a C++ source file and
    /// optional for a C one, which `clangStandard(_:forLanguage:namespace:)` decides once
    /// the file itself is known.
    let std: String?
    let target: String  // e.g. "arm64-apple-macos14.0"

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        target = required.value("target")
        try required.check()

        arguments = []
        environment = [:]
        std = properties["std"]
    }

    /// Where this node's settings live in a config file: `clang.compiler.<key>`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "ClangCompiler")
}

// MARK: - Node

public struct ClangCompiler: Node {
    public static let kind: UInt = 19

    // MARK: Ports

    static let configuration = "configuration"
    static let input = "input"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(configuration), .required(input)],
        outputPorts: [output, errorLog, infoLog]
    )

    // MARK: Processing

    struct ClangCompilerInputs {
        let configuration: ClangCompilerConfiguration
        let inputSourceFile: FileNameAndContent

        init(input: ProcessInput) throws {
            let configurationString = try input.inputValues[ClangCompiler.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = try .init(properties: [String: String](plainText: configurationString))

            let input = input.inputValues[ClangCompiler.input]!.first!
            inputSourceFile = .init(filePath: input.key, hash: try input.value.expectValue())
        }
    }

    struct ClangCompilerOutputs {
        let output: NodeValue
        let errorLog: NodeValue
        let infoLog: NodeValue

        func asProcessOutput() throws -> ProcessOutput {
            .init(outputValues: [ClangCompiler.output: output,
                                 ClangCompiler.errorLog: errorLog,
                                 ClangCompiler.infoLog: infoLog],
                  inputWireSpecs: [:])
        }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    func process(inputs: ClangCompilerInputs) throws -> ClangCompilerOutputs {

        let outputFilename = inputs.inputSourceFile.filePath + ".o"

        let language = ClangPreprocessor.language(for: inputs.inputSourceFile.filePath)

        var arguments = [String]()
        arguments.append("-x");      arguments.append(language)
        arguments.append("-c")

        if let std = try clangStandard(inputs.configuration.std,
                                       forLanguage: language,
                                       namespace: ClangCompilerConfiguration.settingNamespace) {
            arguments.append("-std=\(std)")
        }

        arguments.append(inputs.inputSourceFile.filePath)
        arguments.append("-o");      arguments.append(outputFilename)
        arguments.append("-target"); arguments.append(inputs.configuration.target)
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

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
