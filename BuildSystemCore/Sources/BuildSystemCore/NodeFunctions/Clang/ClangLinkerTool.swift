// ClangLinkerTool.swift
// build_system
//
// Clang linker stage: links one or more .o object files (and optional .dylib
// libraries) into a final output binary.

import Foundation

// MARK: - Configuration

struct ClangLinkerToolConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    let dynamicLibrary: Bool

    init(properties: [String: String]) {
        toolDescriptor = .init(properties: properties)
        arguments = []
        environment = [:]
        dynamicLibrary = properties["dynamicLibrary"] == "true"
    }
}

// MARK: - Node

public struct ClangLinkerTool: NodeFunction {
    public static let kind: UInt = 18

    // MARK: Ports

    static let configuration = "configuration"
    static let input = "objectFiles"
    static let libraries = "libraries"
    static let output = "output"
    static let infoLog = "infoLog"

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    static let descriptor = NodeFunctionDescriptor(
        inputPorts: [
            .required(configuration),
            .required(input),
            .optional(libraries),
        ],
        outputPorts: [output, infoLog]
    )

    // MARK: Processing

    struct ClangLinkerToolInputs {
        let configuration: ClangLinkerToolConfiguration
        let libraryFiles: [FileNameAndContent]
        let objectFiles: [FileNameAndContent]

        init(input: ProcessInput) throws {
            let configurationString = try input.inputValues[ClangCompilerTool.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = .init(properties: [String: String](plainText: configurationString))

            let inputValues = input.inputValues[ClangLinkerTool.input]!
            let libraryValues = input.inputValues[ClangLinkerTool.libraries]!

            var libraryFiles: [FileNameAndContent] = []

            for (libraryName, nodeValue) in libraryValues {
                libraryFiles.append(.init(filePath: libraryName, hash: try nodeValue.expectValue()))
            }

            self.libraryFiles = libraryFiles

            var objectFiles: [FileNameAndContent] = []

            for (objectFileName, nodeValue) in inputValues {
                objectFiles.append(.init(filePath: objectFileName, hash: try nodeValue.expectValue()))
            }

            self.objectFiles = objectFiles
        }
    }

    struct ClangLinkerToolOutputs {
        let output: NodeValue
        let infoLog: NodeValue

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [ClangPreprocessorTool.output: output,
                                 ClangPreprocessorTool.infoLog: infoLog],
                  inputWireExpectations: [:])
        }
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    func process(inputs: ClangLinkerToolInputs) throws -> ClangLinkerToolOutputs {

        var arguments = [String]()

        arguments.append(contentsOf: inputs.configuration.arguments)
        arguments.append("-target"); arguments.append("arm64-apple-macos14.0")
        arguments.append("-L"); arguments.append(".")
        // TODO: lock down SDK version and hash for full hermeticity.
        arguments.append("-L")
        arguments.append("/Applications/Xcode_26_6.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib")
        arguments.append("-lSystem")
        arguments.append("-nostdlib")

        if inputs.configuration.dynamicLibrary {
            arguments.append("-dynamiclib")
        }

        for objectFile in inputs.objectFiles {
            arguments.append(objectFile.filePath)
        }

        for libraryFile in inputs.libraryFiles {
            arguments.append(libraryFile.filePath)
        }

        arguments.append("-o"); arguments.append("output.dylib")
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var inputFiles: [FileNameAndContent] = []
        inputFiles.append(contentsOf: inputs.libraryFiles)
        inputFiles.append(contentsOf: inputs.objectFiles)

        var output: [UInt8] = []
        var errorOutput = ""
        var infoOutput = ""

        let exitCode = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
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
                          })).exitCode

        return .init(output: (exitCode == 0) ? .value(output.intern()) : .noValue(reason: .error(message: errorOutput)),
                     infoLog: .value(infoOutput.intern()))
    }
}
