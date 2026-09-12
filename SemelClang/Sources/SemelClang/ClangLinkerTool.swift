// ClangLinkerTool.swift
// semel
//
// Clang linker stage: links one or more .o object files (and optional .dylib
// libraries) into a final output binary.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct ClangLinkerToolConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    let dynamicLibrary: Bool
    let target: String  // e.g. "arm64-apple-macos14.0"
    let sdkPath: String?
    /// True when the configuration declares `cxxStandard` — the same key the compiler reads
    /// (B-48) — indicating a C++ link that needs `-lc++` beside `-lSystem` even when no
    /// object file is recognisably C++, such as C objects linked against a C++ archive.
    let cxx: Bool

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        target = required.value("target")
        try required.check()

        arguments = []
        environment = [:]
        dynamicLibrary = properties["dynamicLibrary"] == "true"
        sdkPath = properties["sdkPath"]
        cxx = properties["cxxStandard"] != nil
    }

    /// Where this node's settings live in a config file: `clang.linker.<key>`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "ClangLinkerTool")
}

// MARK: - Node

public struct ClangLinkerTool: Node {
    public static let kind: UInt = 18

    // MARK: Ports

    static let configuration = "configuration"
    static let input = "objectFiles"
    static let libraries = "libraries"
    static let output = "output"
    static let infoLog = "infoLog"
    static let fileMetadata = FileMetadata.portName

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .required(configuration),
            .required(input),
            .optional(libraries),
        ],
        outputPorts: [output, infoLog, fileMetadata]
    )

    // MARK: Processing

    struct ClangLinkerToolInputs {
        let configuration: ClangLinkerToolConfiguration
        let libraryFiles: [FileNameAndContent]
        let objectFiles: [FileNameAndContent]

        init(input: ProcessInput) throws {
            let configurationString = try input.inputValues[ClangCompilerTool.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = try .init(properties: [String: String](plainText: configurationString))

            let inputValues = input.inputValues[ClangLinkerTool.input]!
            let libraryValues = input.inputValues[ClangLinkerTool.libraries]!

            // Sorted, not straight out of the dictionary: iteration order for a Swift
            // Dictionary varies from one process to the next, which would put the object
            // and library files on the linker command line in a different order on every
            // run.  A build has to produce the same command line from the same inputs.
            var libraryFiles: [FileNameAndContent] = []

            for (libraryName, nodeValue) in libraryValues.sorted(by: { $0.key < $1.key }) {
                libraryFiles.append(.init(filePath: libraryName, hash: try nodeValue.expectValue()))
            }

            self.libraryFiles = libraryFiles

            var objectFiles: [FileNameAndContent] = []

            for (objectFileName, nodeValue) in inputValues.sorted(by: { $0.key < $1.key }) {
                objectFiles.append(.init(filePath: objectFileName, hash: try nodeValue.expectValue()))
            }

            self.objectFiles = objectFiles
        }
    }

    struct ClangLinkerToolOutputs {
        let output: NodeValue
        let infoLog: NodeValue
        let fileMetadata: NodeValue

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [ClangLinkerTool.output: output,
                                 ClangLinkerTool.infoLog: infoLog,
                                 ClangLinkerTool.fileMetadata: fileMetadata],
                  inputWireExpectations: [:])
        }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    func process(inputs: ClangLinkerToolInputs) throws -> ClangLinkerToolOutputs {

        var arguments = [String]()

        arguments.append(contentsOf: inputs.configuration.arguments)

        arguments.append("-target");
        arguments.append(inputs.configuration.target)

        arguments.append("-L"); arguments.append(".")

        if let sdkPath = inputs.configuration.sdkPath {
            arguments.append("-L"); arguments.append(sdkPath + "/usr/lib")
        }

        arguments.append("-lSystem")

        // Link against libc++ if any object file was compiled from C++ or Objective-C++
        // source, or if the configuration declares a C++ standard (`cxxStandard`).
        let hasCxxObjects = inputs.objectFiles.contains {
            ClangPreprocessorTool.language(for: $0.filePath).hasSuffix("++")
        }

        if hasCxxObjects || inputs.configuration.cxx {
            arguments.append("-lc++")
        }

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

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var inputFiles: [FileNameAndContent] = []
        inputFiles.append(contentsOf: inputs.libraryFiles)
        inputFiles.append(contentsOf: inputs.objectFiles)

        let result = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputFiles,
            expectedOutputFileNames: ["output.dylib"])

        let mode: UInt16 = inputs.configuration.dynamicLibrary ? FileMetadata.defaultMode : FileMetadata.executableMode
        let metadataJSON = (try? FileMetadata(mode: mode).jsonString()) ?? "{}"
        let metadataValue = NodeValue.value(try metadataJSON.intern())

        return .init(output: try result.asOutputNodeValue(),
                     infoLog: .value(try result.infoOutput.intern()),
                     fileMetadata: metadataValue)
    }
}
