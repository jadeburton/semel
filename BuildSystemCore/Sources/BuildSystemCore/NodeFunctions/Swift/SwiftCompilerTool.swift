// SwiftCompilerTool.swift
// build_system
//

import Foundation

// MARK: - Configuration

struct SwiftCompilerToolConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    let moduleName: String

    init(properties: [String: String]) {
        // TODO: remove these defaults and come up with easier way to avoid duplication
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

struct SwiftCompilerTool: NodeFunction {
    static let kind: UInt = 20

    // MARK: Ports

    static let configuration    = "configuration"
    static let inputSourceFiles = "sourceFiles"   // dynamic: one wire per .swift file in the module, self-wired
    static let inputFolder      = "inputFolder"   // manifest to monitor for input swift files and self-wire or unwire
    static let inputModules     = "inputModules"  // one wire per upstream SwiftCompilerTool.outputModule
    static let outputObject     = "object"        // compiled .o
    static let outputModule     = "swiftmodule"
    static let outputInterface  = "swiftinterface"
    static let infoLog          = "infoLog"

    var embeddedNode: Node?

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    let descriptor = NodeFunctionDescriptor(
        staticInputPorts: [configuration, inputFolder, inputModules],
        outputPorts:      [outputObject, outputModule, outputInterface, infoLog],
        dynamicInputPorts: [inputSourceFiles],
        optionalStaticInputPorts: [inputModules]
    )

    // MARK: - Inputs / Outputs

    struct SwiftCompilerToolInputs {
        let configuration: SwiftCompilerToolConfiguration
        let sourceFiles: [FileNameAndContent]
        let moduleFiles: [FileNameAndContent]
        let inputFolderManifests: [(String, FolderManifest)]

        init(input: ProcessInput) throws {
            let configString = try input.inputValues[SwiftCompilerTool.configuration]!
                .values.first!.expectValue().resolveAsString()

            configuration = .init(properties: [String: String](plainText: configString))

            sourceFiles = try (input.inputValues[SwiftCompilerTool.inputSourceFiles] ?? [:])
                .map { fileName, nodeValue in
                    FileNameAndContent(filePath: fileName, hash: try nodeValue.expectValue())
                }
                .sorted { $0.filePath < $1.filePath }

            moduleFiles = try (input.inputValues[SwiftCompilerTool.inputModules] ?? [:])
                .map { fileName, nodeValue in
                    FileNameAndContent(filePath: fileName + ".swiftmodule", hash: try nodeValue.expectValue())
                }
                .sorted { $0.filePath < $1.filePath }

            var allFolderManifests = [(String, FolderManifest)]()

            for (watchedFolderManifestInputKey, watchedFolderManifestInputValue) in input.inputValues[SwiftCompilerTool.inputFolder] ?? [:] {
                let object = try? PolyFactory.decode(encodedJSON: watchedFolderManifestInputValue.expectValue().resolveAsString())

                guard let folderManifest = object as? FolderManifest else {
                    throw NodeError.other(message: "Could not decode FolderManifest")
                }

                allFolderManifests.append((watchedFolderManifestInputKey, folderManifest))
            }

            inputFolderManifests = allFolderManifests
        }
    }

    struct SwiftCompilerToolOutputs {
        let outputObject:    NodeValue
        let outputModule:    NodeValue
        let outputInterface: NodeValue
        let infoLog:         NodeValue
        let inputSourceFilesExpectations: [String: String]

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftCompilerTool.outputObject:    outputObject,
                                 SwiftCompilerTool.outputModule:    outputModule,
                                 SwiftCompilerTool.outputInterface: outputInterface,
                                 SwiftCompilerTool.infoLog:         infoLog],
                  inputWireExpectations: [SwiftCompilerTool.inputSourceFiles: inputSourceFilesExpectations])
        }
    }

    // MARK: - Processing

    func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    private func buildInputSourceFilesExpectations(folderManifests: [(String, FolderManifest)]) -> [String: String] {
        var result: [String: String] = [:]

        for folderManifest in folderManifests {
            for entry in folderManifest.1.entries {
                if entry.isPinned && entry.name.hasSuffix(".swift") {
                    let fullPath = (Path(folderManifest.1.baseFolderPath) / entry.name).string
                    result[fullPath] = "StaticFile(path: \"\(fullPath)\").output".replacingOccurrences(of: "\\'", with: "'")
                }
            }
        }

        return result
    }

    private func compile(inputs: SwiftCompilerToolInputs, inputSourceFilesExpectations: [String: String]) throws -> SwiftCompilerToolOutputs {

        guard !inputs.sourceFiles.isEmpty else {
            let error = NodeValue.noValue(reason: .error(message: "SwiftCompilerTool: no source files"))
            return .init(outputObject: error,
                         outputModule: error,
                         outputInterface: error,
                         infoLog: .value("".intern()),
                         inputSourceFilesExpectations: inputSourceFilesExpectations)
        }

        let moduleName      = inputs.configuration.moduleName
        let objectOutput    = "\(moduleName).o"
        let moduleOutput    = "\(moduleName).swiftmodule"
        let interfaceOutput = "\(moduleName).swiftinterface"

        var arguments = [String]()

        if let sdkPath = resolveSDKPath() {
            arguments.append("-sdk");                        arguments.append(sdkPath)
        }

        arguments.append("-module-name");                    arguments.append(moduleName)
        if moduleName != "MainTarget" { // HACK
            arguments.append("-parse-as-library")
        }
        arguments.append("-c")
        arguments.append("-whole-module-optimization")
        arguments.append("-o");                              arguments.append(objectOutput)
        arguments.append("-emit-module")
        arguments.append("-emit-module-path");               arguments.append(moduleOutput)
        arguments.append("-emit-module-interface")
        arguments.append("-emit-module-interface-path");     arguments.append(interfaceOutput)

        if !inputs.moduleFiles.isEmpty {
            arguments.append("-I"); arguments.append(".")
        }

        for sourceFile in inputs.sourceFiles {
            arguments.append(sourceFile.filePath)
        }

        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var objectBytes:    [UInt8] = []
        var moduleBytes:    [UInt8] = []
        var interfaceBytes: [UInt8] = []
        var errorOutput = ""
        var infoOutput  = ""

        let exitCode = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputs.sourceFiles + inputs.moduleFiles,
            expectedOutputFileNames: [objectOutput, moduleOutput, interfaceOutput],
            output: .init(
                logError:   { message in errorOutput += message + "\n"; },
                logMessage: { message in infoOutput  += message + "\n"; },
                write: { filename, data in
                    if filename == objectOutput {
                        objectBytes.append(contentsOf: data)
                    } else if filename == moduleOutput {
                        moduleBytes.append(contentsOf: data)
                    } else if filename == interfaceOutput {
                        interfaceBytes.append(contentsOf: data)
                    }
                }))

        guard exitCode == 0 else {
            let error = NodeValue.noValue(reason: .error(message: errorOutput))
            return .init(outputObject: error,
                         outputModule: error,
                         outputInterface: error,
                         infoLog: .value(infoOutput.intern()),
                         inputSourceFilesExpectations: inputSourceFilesExpectations)
        }

        return .init(outputObject:    .value(objectBytes.intern()),
                     outputModule:    .value(moduleBytes.intern()),
                     outputInterface: .value(interfaceBytes.intern()),
                     infoLog:         .value(infoOutput.intern()),
                     inputSourceFilesExpectations: inputSourceFilesExpectations)
    }

    private func process(inputs: SwiftCompilerToolInputs) -> SwiftCompilerToolOutputs {
        let inputSourceFilesExpectations = buildInputSourceFilesExpectations(folderManifests: inputs.inputFolderManifests)
        do {
            return try compile(inputs: inputs, inputSourceFilesExpectations: inputSourceFilesExpectations)
        } catch {
            let errorNodeValue = NodeValue.noValue(reason: .error(message: error.localizedDescription))
            return .init(outputObject: errorNodeValue,
                         outputModule: errorNodeValue,
                         outputInterface: errorNodeValue,
                         infoLog: .value("".intern()),
                         inputSourceFilesExpectations: inputSourceFilesExpectations)
        }
    }
}
