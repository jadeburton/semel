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

// MARK: - SDK path helper

/// Resolves the current macOS SDK path by running `xcrun --show-sdk-path --sdk macosx`.
/// This is needed when invoking swiftc directly (outside xcodebuild) so it can
/// locate the Swift standard library.
private func resolveSDKPath() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--show-sdk-path", "--sdk", "macosx"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()   // suppress xcrun warnings
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    } catch {
        return nil
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

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    let descriptor = NodeFunctionDescriptor(staticInputPorts: [configuration, input],
                                            outputPorts: [output, infoLog])

    // MARK: Processing

    struct SwiftCompilerToolInputs {
        let configuration: SwiftCompilerToolConfiguration
        let inputSourceFile: FileNameAndContent

        init(input: ProcessInput) throws {
            let configurationString = try input.inputValues[SwiftCompilerTool.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = .init(properties: [String: String](plainText: configurationString))

            let sourceFile = input.inputValues[SwiftCompilerTool.input]!.first!
            inputSourceFile = .init(filePath: sourceFile.key, hash: try sourceFile.value.expectValue())
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

        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var output: [UInt8] = []
        var errorOutput = ""
        var infoOutput = ""

        let exitCode = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: [.init(filePath: inputs.inputSourceFile.filePath,
                               hash: inputs.inputSourceFile.hash)],
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
