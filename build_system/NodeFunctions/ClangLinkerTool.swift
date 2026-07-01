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
        toolDescriptor = .init(name: properties["toolDescriptor.name"] ?? "clang",
                               version: properties["toolDescriptor.version"] ?? "Apple clang version 17.0.0 (clang-1700.6.3.2)",
                               platform: properties["toolDescriptor.platform"] ?? "macOS",
                               architecture: properties["toolDescriptor.architecture"] ?? "arm64",
                               recursiveHash: properties["toolDescriptor.recursiveHash"] ?? "")
        arguments = []
        environment = [:]
        dynamicLibrary = properties["dynamicLibrary"] == "true"
    }

    func asDictionary() -> [String: String] {
        ["toolDescriptor.name": toolDescriptor.name,
         "toolDescriptor.version": toolDescriptor.version,
         "toolDescriptor.platform": toolDescriptor.platform,
         "toolDescriptor.architecture": toolDescriptor.architecture,
         "toolDescriptor.recursiveHash": toolDescriptor.recursiveHash ?? "",
         "dynamicLibrary": dynamicLibrary ? "true" : "false"]
    }
}

// MARK: - Node

struct ClangLinkerTool: NodeFunction {
    static let kind: UInt = 18

    // MARK: Ports

    static let configuration = "configuration"

    // TODO: rename to "objectFiles"
    static let input = "input"

    static let libraries = "libraries"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [configuration, input, libraries],
                                            outputPorts: [output, errorLog, infoLog],
                                            optionalStaticInputPorts: [libraries])

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
                libraryFiles.append(.init(filePath: libraryName, content: try nodeValue.expectValue().resolve()))
            }

            self.libraryFiles = libraryFiles

            var objectFiles: [FileNameAndContent] = []

            for (objectFileName, nodeValue) in inputValues {
                objectFiles.append(.init(filePath: objectFileName, content: try nodeValue.expectValue().resolve()))
            }

            self.objectFiles = objectFiles
        }
    }

    struct ClangLinkerToolOutputs {
        let output: NodeValue
        let errorLog: NodeValue
        let infoLog: NodeValue

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [ClangPreprocessorTool.output: output,
                                 ClangPreprocessorTool.errorLog: errorLog,
                                 ClangPreprocessorTool.infoLog: infoLog],
                  inputWireExpectations: [:])
        }
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        let inputs = try ClangLinkerToolInputs(input: input)
        return try process(inputs: inputs).asProcessOutput()
    }

    func process(inputs: ClangLinkerToolInputs) throws -> ClangLinkerToolOutputs {

        var arguments = [String]()

        arguments.append(contentsOf: inputs.configuration.arguments)
        arguments.append("-target"); arguments.append("arm64-apple-macos14.0")
        arguments.append("-L"); arguments.append(".")
        // TODO: lock down SDK version and hash for full hermeticity.
        arguments.append("-L")
        arguments.append("/Applications/Xcode_26_2.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib")
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
                          }))

        return .init(output: (exitCode == 0) ? .value(output.intern()) : .noValue(reason: .error(message: "Linker exited with exitcode \(exitCode)")),
                     errorLog: .value(errorOutput.intern()),
                     infoLog: .value(infoOutput.intern()))
    }
}
