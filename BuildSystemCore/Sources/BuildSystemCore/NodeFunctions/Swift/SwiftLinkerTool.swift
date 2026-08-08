// SwiftLinkerTool.swift
// build_system
//
// Swift linker stage: links one or more .o object files into a final
// executable or dynamic library using `swiftc` as the driver.

import Foundation

// MARK: - Configuration

struct SwiftLinkerToolConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    let dynamicLibrary: Bool
    let outputName: String

    init(properties: [String: String]) {
        toolDescriptor = .init(
            name: properties["toolDescriptor.name"] ?? "swiftc",
            version: properties["toolDescriptor.version"] ?? "Apple Swift version 6.2.3",
            platform: properties["toolDescriptor.platform"] ?? "macOS",
            architecture: properties["toolDescriptor.architecture"] ?? "arm64",
            recursiveHash: properties["toolDescriptor.recursiveHash"] ?? "")
        arguments = []
        environment = [:]
        dynamicLibrary = properties["dynamicLibrary"] == "true"
        outputName = properties["outputName"] ?? (dynamicLibrary ? "output.dylib" : "output")
    }

    func asDictionary() -> [String: String] {
        ["toolDescriptor.name": toolDescriptor.name,
         "toolDescriptor.version": toolDescriptor.version,
         "toolDescriptor.platform": toolDescriptor.platform,
         "toolDescriptor.architecture": toolDescriptor.architecture,
         "toolDescriptor.recursiveHash": toolDescriptor.recursiveHash ?? "",
         "dynamicLibrary": dynamicLibrary ? "true" : "false",
         "outputName": outputName]
    }
}

// MARK: - Node

struct SwiftLinkerTool: NodeFunction {
    static let kind: UInt = 21

    // MARK: Ports

    static let configuration = "configuration"
    static let input = "input"
    static let libraries = "libraries"
    static let output = "output"
    static let infoLog = "infoLog"

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    static let descriptor = NodeFunctionDescriptor(
        staticInputPorts: [configuration, input, libraries],
        outputPorts: [output, infoLog],
        optionalStaticInputPorts: [libraries])

    // MARK: Processing

    struct SwiftLinkerToolInputs {
        let configuration: SwiftLinkerToolConfiguration
        let objectFiles: [FileNameAndContent]
        let libraryFiles: [FileNameAndContent]

        init(input: ProcessInput) throws {
            let configurationString = try input.inputValues[SwiftLinkerTool.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = .init(properties: [String: String](plainText: configurationString))

            var objectFiles: [FileNameAndContent] = []
            for (fileName, nodeValue) in input.inputValues[SwiftLinkerTool.input]! {
                objectFiles.append(.init(filePath: fileName, hash: try nodeValue.expectValue()))
            }
            self.objectFiles = objectFiles

            var libraryFiles: [FileNameAndContent] = []
            for (fileName, nodeValue) in input.inputValues[SwiftLinkerTool.libraries]! {
                libraryFiles.append(.init(filePath: fileName, hash: try nodeValue.expectValue()))
            }
            self.libraryFiles = libraryFiles
        }
    }

    struct SwiftLinkerToolOutputs {
        let output: NodeValue
        let infoLog: NodeValue

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftLinkerTool.output: output,
                                 SwiftLinkerTool.infoLog: infoLog],
                  inputWireExpectations: [:])
        }
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    func process(inputs: SwiftLinkerToolInputs) throws -> SwiftLinkerToolOutputs {

        let outputName = inputs.configuration.outputName

        var arguments = [String]()

        if inputs.configuration.dynamicLibrary {
            arguments.append("-emit-library")
        }

        // Pass the SDK path so swiftc's linker driver can find libSystem and
        // other system libraries when invoked directly (outside of xcodebuild).
        if let sdkPath = resolveSDKPath() {
            arguments.append("-sdk")
            arguments.append(sdkPath)
        }

        for objectFile in inputs.objectFiles {
            arguments.append(objectFile.filePath)
        }

        for libraryFile in inputs.libraryFiles {
            arguments.append(libraryFile.filePath)
        }

        arguments.append("-o"); arguments.append(outputName)
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var inputFiles: [FileNameAndContent] = []
        inputFiles.append(contentsOf: inputs.objectFiles)
        inputFiles.append(contentsOf: inputs.libraryFiles)

        var output: [UInt8] = []
        var errorOutput = ""
        var infoOutput = ""

        let exitCode = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputFiles,
            expectedOutputFileNames: [outputName],
            output: .init(
                logError: { error in
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

        return .init(
            output: (exitCode == 0)
                ? .value(output.intern())
                : .noValue(reason: .error(message: errorOutput)),
            infoLog: .value(infoOutput.intern()))
    }
}
