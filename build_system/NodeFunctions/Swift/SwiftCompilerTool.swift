// SwiftCompilerTool.swift
// build_system
//
// Swift compiler stage: compiles a .swift source file into a .o object file
// using `swiftc -c`.

import Foundation

// MARK: - Configuration

struct SwiftCompilerToolConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    let moduleName: String

    init(properties: [String: String]) {
        toolDescriptor = .init(
            name: properties["toolDescriptor.name"] ?? "swiftc",
            version: properties["toolDescriptor.version"] ?? "Apple Swift version 6.2.3",
            platform: properties["toolDescriptor.platform"] ?? "macOS",
            architecture: properties["toolDescriptor.architecture"] ?? "arm64",
            recursiveHash: properties["toolDescriptor.recursiveHash"] ?? "")
        arguments = []
        environment = [:]
        moduleName = properties["moduleName"] ?? "main"
    }

    func asDictionary() -> [String: String] {
        ["toolDescriptor.name": toolDescriptor.name,
         "toolDescriptor.version": toolDescriptor.version,
         "toolDescriptor.platform": toolDescriptor.platform,
         "toolDescriptor.architecture": toolDescriptor.architecture,
         "toolDescriptor.recursiveHash": toolDescriptor.recursiveHash ?? "",
         "moduleName": moduleName]
    }
}

// MARK: - Node

struct SwiftCompilerTool: NodeFunction {
    static let kind: UInt = 20

    // MARK: Ports

    static let configuration = "configuration"
    static let input = "input"
    static let output = "output"
    static let infoLog = "infoLog"
    static let swiftmodule   = "swiftmodule"   // output of SwiftModuleTool for this module

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    let descriptor = NodeFunctionDescriptor(
        staticInputPorts:         [configuration, input, swiftmodule],
        outputPorts:              [output, infoLog],
        optionalStaticInputPorts: [swiftmodule])

    // MARK: Processing

    struct SwiftCompilerToolInputs {
        let configuration: SwiftCompilerToolConfiguration
        let inputSourceFile: FileNameAndContent
        /// Optional .swiftmodule from SwiftModuleTool. When present it is written
        /// into the sandbox so swiftc can resolve cross-file type references via -I .
        let swiftmoduleFile: FileNameAndContent?

        init(input: ProcessInput) throws {
            let configurationString = try input.inputValues[SwiftCompilerTool.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = .init(properties: [String: String](plainText: configurationString))

            let sourceFile = input.inputValues[SwiftCompilerTool.input]!.first!
            inputSourceFile = .init(filePath: sourceFile.key, hash: try sourceFile.value.expectValue())

            // swiftmodule is optional — single-file modules don't need it
            if let moduleEntry = input.inputValues[SwiftCompilerTool.swiftmodule]?.first {
                swiftmoduleFile = .init(filePath: moduleEntry.key,
                                        hash: try moduleEntry.value.expectValue())
            } else {
                swiftmoduleFile = nil
            }
        }
    }

    struct SwiftCompilerToolOutputs {
        let output: NodeValue
        let infoLog: NodeValue

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftCompilerTool.output: output,
                                 SwiftCompilerTool.infoLog: infoLog],
                  inputWireExpectations: [:])
        }
    }

    func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    func process(inputs: SwiftCompilerToolInputs) throws -> SwiftCompilerToolOutputs {

        let outputFilename = inputs.inputSourceFile.filePath + ".o"

        var arguments = [String]()
        arguments.append("-c")
        arguments.append(inputs.inputSourceFile.filePath)
        arguments.append("-o");           arguments.append(outputFilename)
        arguments.append("-module-name"); arguments.append(inputs.configuration.moduleName)

        // Pass the SDK path so swiftc can locate the Swift standard library when
        // invoked directly (i.e. outside of xcodebuild / Xcode's build system).
        if let sdkPath = resolveSDKPath(), !sdkPath.isEmpty {
            arguments.append("-sdk")
            arguments.append(sdkPath)
        }

        // If a .swiftmodule was provided, tell swiftc to search the sandbox
        // working directory for it so cross-file type references resolve.
        if inputs.swiftmoduleFile != nil {
            arguments.append("-I")
            arguments.append(".")
        }

        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        // Include the .swiftmodule in the sandbox so swiftc can find it via -I .
        var inputFiles: [FileNameAndContent] = [inputs.inputSourceFile]
        if let moduleFile = inputs.swiftmoduleFile {
            inputFiles.append(moduleFile)
        }

        var output: [UInt8] = []
        var errorOutput = ""
        var infoOutput = ""

        let exitCode = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputFiles,
            expectedOutputFileNames: [outputFilename],
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
                }))

        return .init(
            output: (exitCode == 0)
                ? .value(output.intern())
                : .noValue(reason: .error(message: errorOutput)),
            infoLog: .value(infoOutput.intern()))
    }
}
