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

final class ClangCompilerTool: NodeType {
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

    static let configuration = NodeKindDescriptor.InputPort(index: 0,
                                                            name: "configuration",
                                                            kind: .value(dataType: .utf8Text),
                                                            maximumConnections: 1,
                                                            minimumConnections: 1)

    static let input = NodeKindDescriptor.InputPort(index: 1,
                                                    name: "input",
                                                    kind: .value(dataType: .utf8Text),
                                                    maximumConnections: 1,
                                                    minimumConnections: 1)

    static let output = NodeKindDescriptor.OutputPort(index: 2,
                                                      name: "output",
                                                      kind: .value(dataType: .binary))

    static let errorLog = NodeKindDescriptor.OutputPort(index: 0,
                                                        name: "errorLog",
                                                        kind: .stream(dataType: .utf8Text))

    static let infoLog = NodeKindDescriptor.OutputPort(index: 1,
                                                       name: "infoLog",
                                                       kind: .stream(dataType: .utf8Text))

    var descriptor: NodeKindDescriptor {
        .init(kind: Self.kind,
              inputs: [Self.configuration, Self.input],
              outputs: [Self.output, Self.errorLog, Self.infoLog])
    }

    // MARK: Processing

    func process() throws {

        guard let configuration: ClangCompilerToolConfiguration = try readConfiguration(fromInputPort: Self.configuration) else {
            return
        }

        guard let firstInputValue = try readOneValueFromInputPort(Self.input) else {
            return
        }

        switch firstInputValue.kind {

        case .noValue:
            try writeToOutputPort(Self.output, value: .noValue(reason: .error(message: "Input has no value")))
            return

        case .value(let payload, let metadata):

            let bytes = try payload.expectDataObjectHash().resolve()
            var output: [UInt8] = []

            let inputFilename: String
            if let fileMetadata = metadata as? FileMetadata {
                inputFilename = fileMetadata.name
            } else {
                inputFilename = "source.pc"
            }
            let outputFilename = inputFilename + ".o"

            var arguments = [String]()
            arguments.append("-x");      arguments.append("c")
            arguments.append("-c")
            arguments.append(inputFilename)
            arguments.append("-o");      arguments.append(outputFilename)
            arguments.append("-target"); arguments.append("arm64-apple-macos14.0")
            arguments.append(contentsOf: configuration.arguments)

            let tool = try ToolExecutorRegistry.instance.tool(descriptor: configuration.toolDescriptor)

            let exitCode = try tool.execute(
                arguments: arguments,
                environment: configuration.environment,
                inputFiles: [.init(filePath: inputFilename, content: bytes)],
                expectedOutputFileNames: [outputFilename],
                output: .init(logError:   { error   in print(error)   },
                              logMessage: { message in print(message) },
                              write:      { _, data in output.append(contentsOf: data) }))

            if exitCode == 0 {
                try writeToOutputPort(Self.output, value: .value(.dataObjectHash(output.intern()),
                                                                 metadata: FileMetadata(name: outputFilename)))
            } else {
                try writeToOutputPort(Self.output, value: .noValue(reason: .error(message: "Compiler exited with nonzero status")))
            }
        }
    }
}
