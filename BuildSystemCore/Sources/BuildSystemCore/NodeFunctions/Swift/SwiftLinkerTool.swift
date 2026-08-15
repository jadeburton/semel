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
            version: properties["toolDescriptor.version"] ?? "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)",
            platform: properties["toolDescriptor.platform"] ?? "macOS",
            architecture: properties["toolDescriptor.architecture"] ?? "arm64",
            recursiveHash: properties["toolDescriptor.recursiveHash"])
        arguments = []
        environment = [:]
        dynamicLibrary = properties["dynamicLibrary"] == "true"
        outputName = properties["outputName"] ?? (dynamicLibrary ? "output.dylib" : "output")
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
    /// Declaring this port is what makes ProjectBuilder wire the linked file's Unix mode
    /// into its OutputFile wrapper, so `cp` can chmod it. Without it an executable is
    /// published at the default 0644 and will not run. Same arrangement as ClangLinkerTool.
    static let fileMetadata = FileMetadata.portName

    var embeddedNode: Node

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    static let descriptor = NodeFunctionDescriptor(
        inputPorts: [
            .required(configuration),
            .required(input),
            .optional(libraries),
        ],
        outputPorts: [output, infoLog, fileMetadata]
    )

    // MARK: Processing

    struct SwiftLinkerToolInputs {
        let configuration: SwiftLinkerToolConfiguration
        let objectFiles: [FileNameAndContent]
        let libraryFiles: [FileNameAndContent]

        init(input: ProcessInput) throws {
            let configurationString = try input.inputValues[SwiftLinkerTool.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = .init(properties: [String: String](plainText: configurationString))

            // Sorted: these go straight onto the command line, and Swift Dictionary
            // iteration order changes from one process to the next.
            var objectFiles: [FileNameAndContent] = []
            for (fileName, nodeValue) in input.inputValues[SwiftLinkerTool.input]!.sorted(by: { $0.key < $1.key }) {
                objectFiles.append(.init(filePath: fileName, hash: try nodeValue.expectValue()))
            }
            self.objectFiles = objectFiles

            var libraryFiles: [FileNameAndContent] = []
            for (fileName, nodeValue) in input.inputValues[SwiftLinkerTool.libraries]!.sorted(by: { $0.key < $1.key }) {
                libraryFiles.append(.init(filePath: fileName, hash: try nodeValue.expectValue()))
            }
            self.libraryFiles = libraryFiles
        }
    }

    struct SwiftLinkerToolOutputs {
        let output: NodeValue
        let infoLog: NodeValue
        let fileMetadata: NodeValue

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftLinkerTool.output: output,
                                 SwiftLinkerTool.infoLog: infoLog,
                                 SwiftLinkerTool.fileMetadata: fileMetadata],
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

        let result = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputFiles,
            expectedOutputFileNames: [outputName])

        // A dynamic library is loaded, not run, so only an executable needs the x bits.
        let mode: UInt16 = inputs.configuration.dynamicLibrary ? FileMetadata.defaultMode : FileMetadata.executableMode
        let metadataJSON = (try? FileMetadata(mode: mode).jsonString()) ?? "{}"

        return .init(output: try result.asOutputNodeValue(),
                     infoLog: .value(try result.infoOutput.intern()),
                     fileMetadata: .value(try metadataJSON.intern()))
    }
}
