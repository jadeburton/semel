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

final class ClangCompilerTool: NodeFunction {
    static let kind: UInt = 19

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

    static let configuration = "configuration"
    static let input = "input"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [configuration, input],
                                            staticOutputPorts: [output, errorLog, infoLog])

    // MARK: Processing

    // The process method cannot access any information outside of what is passed to it. This is because doing so would bypass the caching system.
    // Also, what is passed to it cannot contain any surrogate identifiers, as we want the cache to be universal and sharable between different
    // machines and different runs.
    func process(inputs: [String: [NodeValueKind]]) throws -> [String: NodeValueKind] {
        [:]
    }

//    func process<I, O>(inputs: I) throws -> O {
//    }

    struct ClangCompilerToolInputs {
        private let rawInputs: [String: [NodeValueKind]]

        var configuration: String { get throws { try rawInputs[ClangCompilerTool.configuration]!.first!.expectValue().resolveAsString() } }
        var inputSourceFile: String {  get throws { try rawInputs[ClangCompilerTool.input]!.first!.expectValue().resolveAsString() } }

        init(rawInputs: [String: [NodeValueKind]]) {
            self.rawInputs = rawInputs
        }
    }

    struct ClangCompilerToolOutputs {
    }

    func process(inputs: ClangCompilerToolInputs) throws -> ClangCompilerToolOutputs {
        .init()
    }

    func process() throws {

        let configuration: ClangCompilerToolConfiguration = try readConfiguration(fromInputPort: Self.configuration)
        let inputValue = try readOneValueFromInputPort(Self.input)

        let bytes = try inputValue.dataObjectHash.resolve()
        var output: [UInt8] = []

        let inputFilename = "source.pc"
        let outputFilename = inputFilename + ".o"

        var arguments = [String]()
        arguments.append("-x");      arguments.append("c")
        arguments.append("-c")
        arguments.append(inputFilename)
        arguments.append("-o");      arguments.append(outputFilename)
        arguments.append("-target"); arguments.append("arm64-apple-macos14.0")
        arguments.append(contentsOf: configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: configuration.toolDescriptor)

        var errorOutput = ""
        var infoOutput = ""

        let exitCode = try tool.execute(
            arguments: arguments,
            environment: configuration.environment,
            inputFiles: [.init(filePath: inputFilename, content: bytes)],
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
            try writeToOutputPort(Self.output, value: .noValue(reason: .error(message: "Compiler exited with nonzero status")))
        }
    }
}
