// SwiftModuleTool.swift
// build_system
//
// Module-emit stage: takes all .swift source files for a module and produces
// a single .swiftmodule file that encodes the module's public type interface.
//
// This is Stage 1 of a two-stage Swift build:
//   Stage 1 — SwiftModuleTool  : all .swift files → Module.swiftmodule
//   Stage 2 — SwiftCompilerTool: one .swift file + Module.swiftmodule → file.swift.o
//
// Separating the stages means that when a single source file changes:
//   • If its public interface changed  → swiftmodule hash changes → all .o rebuilt (correct)
//   • If only its implementation changed → swiftmodule hash unchanged → only that one .o rebuilt

import Foundation

// MARK: - Configuration

struct SwiftModuleToolConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    let moduleName: String

    init(properties: [String: String]) {
        toolDescriptor = .init(
            name:          properties["toolDescriptor.name"]          ?? "swiftc",
            version:       properties["toolDescriptor.version"]       ?? "Apple Swift version 6.2.3",
            platform:      properties["toolDescriptor.platform"]      ?? "macOS",
            architecture:  properties["toolDescriptor.architecture"]  ?? "arm64",
            recursiveHash: properties["toolDescriptor.recursiveHash"] ?? "")
        arguments   = []
        environment = [:]
        moduleName  = properties["moduleName"] ?? "Module"
    }

    func asDictionary() -> [String: String] {
        ["toolDescriptor.name":          toolDescriptor.name,
         "toolDescriptor.version":       toolDescriptor.version,
         "toolDescriptor.platform":      toolDescriptor.platform,
         "toolDescriptor.architecture":  toolDescriptor.architecture,
         "toolDescriptor.recursiveHash": toolDescriptor.recursiveHash ?? "",
         "moduleName":                   moduleName]
    }
}

// MARK: - Node

struct SwiftModuleTool: NodeFunction {
    static let kind: UInt = 22

    // MARK: Ports

    static let configuration = "configuration"
    static let input         = "input"          // one wire per .swift file in the module
    static let output        = "output"         // the .swiftmodule bytes
    static let infoLog       = "infoLog"

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [input, configuration],
                                            outputPorts: [output, infoLog])

    // MARK: - Inputs / Outputs

    struct SwiftModuleToolInputs {
        let configuration: SwiftModuleToolConfiguration
        let sourceFiles: [FileNameAndContent]   // all .swift files, keyed by filename

        init(input: ProcessInput) throws {
            let configString = try input.inputValues[SwiftModuleTool.configuration]!
                .values.first!.expectValue().resolveAsString()
            configuration = .init(properties: [String: String](plainText: configString))

            sourceFiles = try (input.inputValues[SwiftModuleTool.input] ?? [:])
                .map { fileName, nodeValue in
                    FileNameAndContent(filePath: fileName,
                                       hash: try nodeValue.expectValue())
                }
                .sorted { $0.filePath < $1.filePath }   // stable order → stable cache key
        }
    }

    struct SwiftModuleToolOutputs {
        let output:  NodeValue
        let infoLog: NodeValue

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftModuleTool.output:  output,
                                 SwiftModuleTool.infoLog: infoLog],
                  inputWireExpectations: [:])
        }
    }

    // MARK: - Processing

    func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    func process(inputs: SwiftModuleToolInputs) throws -> SwiftModuleToolOutputs {
        guard !inputs.sourceFiles.isEmpty else {
            return .init(output:  .noValue(reason: .error(message: "SwiftModuleTool: no source files")),
                         infoLog: .value("".intern()))
        }

        let moduleName    = inputs.configuration.moduleName
        let moduleOutput  = "\(moduleName).swiftmodule"

        var arguments = [String]()

        if let sdkPath = resolveSDKPath() {
            arguments.append("-sdk");           arguments.append(sdkPath)
        }

        arguments.append("-module-name");       arguments.append(moduleName)
        arguments.append("-parse-as-library")   // don't look for a @main / top-level code
        arguments.append("-emit-module")
        arguments.append("-emit-module-path");  arguments.append(moduleOutput)

        // All source files as positional arguments
        for sourceFile in inputs.sourceFiles {
            arguments.append(sourceFile.filePath)
        }

        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var moduleBytes: [UInt8] = []
        var errorOutput = ""
        var infoOutput  = ""

        let exitCode = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputs.sourceFiles,
            expectedOutputFileNames: [moduleOutput],
            output: .init(
                logError: { message in errorOutput += message + "\n"; print(message) },
                logMessage: { message in infoOutput  += message + "\n"; print(message) },
                write: { _, data in moduleBytes.append(contentsOf: data) }))

        return .init(output: (exitCode == 0) ? .value(moduleBytes.intern()) : .noValue(reason: .error(message: errorOutput)),
                     infoLog: .value(infoOutput.intern()))
    }
}
