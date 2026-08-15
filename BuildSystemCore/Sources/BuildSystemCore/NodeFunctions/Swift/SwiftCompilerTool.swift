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
    let parseAsLibrary: Bool

    init(properties: [String: String]) {
        // TODO: remove these defaults and come up with easier way to avoid duplication
        toolDescriptor = .init(
            name:          properties["toolDescriptor.name"]          ?? "swiftc",
            version:       properties["toolDescriptor.version"]       ?? "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)",
            platform:      properties["toolDescriptor.platform"]      ?? "macOS",
            architecture:  properties["toolDescriptor.architecture"]  ?? "arm64",
            recursiveHash: properties["toolDescriptor.recursiveHash"])
        arguments   = []
        environment = [:]
        moduleName  = properties["moduleName"] ?? "Module"
        parseAsLibrary = properties["parseAsLibrary"] != "false"
    }
}

// MARK: - Node

struct SwiftCompilerTool: NodeFunction {
    static let kind: UInt = 20
    static let codeVersion: Int = 1

    // MARK: Ports

    static let configuration         = "configuration"
    static let inputSourceFiles      = "sourceFiles"          // dynamic: one wire per .swift file
    static let inputFolder           = "inputFolder"          // manifest to watch for swift files
    static let inputModules          = "inputModules"         // one wire per upstream swiftmodule
    /// Folder manifests for system-library targets (e.g. GRDBSQLite).
    /// Each entry key becomes the subdirectory name placed in the sandbox.
    static let inputModuleMapFolders = "inputModuleMapFolders"
    /// Dynamic port — actual file content wired from StaticFile nodes discovered
    /// via inputModuleMapFolders.  Wire key format: "<dirName>/<filename>".
    static let inputModuleMapFiles   = "inputModuleMapFiles"
    static let outputObject          = "object"
    static let outputModule          = "swiftmodule"
    static let outputInterface       = "swiftinterface"
    static let infoLog               = "infoLog"

    var embeddedNode: Node

    init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    static let descriptor = NodeFunctionDescriptor(
        inputPorts: [
            .required(configuration),
            .required(inputFolder),
            .optional(inputModules),
            .optional(inputModuleMapFolders),
            .dynamic(inputSourceFiles),
            .dynamic(inputModuleMapFiles),
        ],
        outputPorts: [outputObject, outputModule, outputInterface, infoLog]
    )

    // MARK: - Inputs / Outputs

    struct SwiftCompilerToolInputs {
        let configuration: SwiftCompilerToolConfiguration
        let sourceFiles: [FileNameAndContent]
        let moduleFiles: [FileNameAndContent]
        let moduleMapFiles: [FileNameAndContent]
        let inputFolderManifests: [(String, FolderManifest)]
        let moduleMapFolderManifests: [(String, FolderManifest)]

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

            // Module map files: wire key is already "<dirName>/<filename>".
            moduleMapFiles = try (input.inputValues[SwiftCompilerTool.inputModuleMapFiles] ?? [:])
                .map { wireKey, nodeValue in
                    FileNameAndContent(filePath: wireKey, hash: try nodeValue.expectValue())
                }
                .sorted { $0.filePath < $1.filePath }

            // Sorted for the same reason the source file list above is sorted: these
            // become an ordered list feeding the command line, and dictionary iteration
            // order is not stable across processes.
            var allFolderManifests = [(String, FolderManifest)]()
            for (key, value) in (input.inputValues[SwiftCompilerTool.inputFolder] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let object = try? PolyFactory.decode(encodedJSON: value.expectValue().resolveAsString())
                guard let folderManifest = object as? FolderManifest else {
                    throw NodeError.other(message: "Could not decode FolderManifest")
                }
                allFolderManifests.append((key, folderManifest))
            }
            inputFolderManifests = allFolderManifests

            var allModuleMapFolders = [(String, FolderManifest)]()
            for (key, value) in (input.inputValues[SwiftCompilerTool.inputModuleMapFolders] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let jsonStr = try? value.expectValue().resolveAsString(),
                      let manifest = try? PolyFactory.decode(encodedJSON: jsonStr) as? FolderManifest
                else { continue }
                allModuleMapFolders.append((key, manifest))
            }
            moduleMapFolderManifests = allModuleMapFolders
        }
    }

    struct SwiftCompilerToolOutputs {
        let outputObject:    NodeValue
        let outputModule:    NodeValue
        let outputInterface: NodeValue
        let infoLog:         NodeValue
        let inputSourceFilesExpectations:    [String: String]
        let inputModuleMapFilesExpectations: [String: String]

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftCompilerTool.outputObject:    outputObject,
                                 SwiftCompilerTool.outputModule:    outputModule,
                                 SwiftCompilerTool.outputInterface: outputInterface,
                                 SwiftCompilerTool.infoLog:         infoLog],
                  inputWireExpectations: [
                      SwiftCompilerTool.inputSourceFiles:    inputSourceFilesExpectations,
                      SwiftCompilerTool.inputModuleMapFiles: inputModuleMapFilesExpectations
                  ])
        }
    }

    // MARK: - Processing

    func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    private func buildInputSourceFilesExpectations(folderManifests: [(String, FolderManifest)]) -> [String: String] {
        var result: [String: String] = [:]
        for folderManifest in folderManifests {
            for entry in folderManifest.1.entries where entry.isPinned && entry.name.hasSuffix(".swift") && !entry.isFolder {
                let fullPath = (Path(folderManifest.1.baseFolderPath) / entry.name).string
                result[fullPath] = "StaticFile(path: \"\(fullPath)\").output".replacingOccurrences(of: "\\'", with: "'")
            }
        }
        return result
    }

    /// Generates dynamic wire expectations for all files inside each system-library
    /// folder manifest.  Wire key format: "<sandboxDirName>/<filename>".
    private func buildInputModuleMapFilesExpectations(moduleMapFolderManifests: [(String, FolderManifest)]) -> [String: String] {
        var result: [String: String] = [:]
        for (dirName, manifest) in moduleMapFolderManifests {
            for entry in manifest.entries where entry.isPinned && !entry.isFolder {
                let wireKey = Path(dirName) / entry.name
                result[wireKey.string] = "StaticFile(path: \"\(Path(manifest.baseFolderPath) / entry.name)\").output"
            }
        }
        return result
    }

    private func compile(inputs: SwiftCompilerToolInputs,
                         inputSourceFilesExpectations: [String: String],
                         inputModuleMapFilesExpectations: [String: String]) throws -> SwiftCompilerToolOutputs {

        guard !inputs.sourceFiles.isEmpty else {
            let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try "SwiftCompilerTool: no source files".intern()))
            return .init(outputObject: error,
                         outputModule: error,
                         outputInterface: error,
                         infoLog: .value(""),
                         inputSourceFilesExpectations: inputSourceFilesExpectations,
                         inputModuleMapFilesExpectations: inputModuleMapFilesExpectations)
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

        if inputs.configuration.parseAsLibrary {
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

        // Add -I flags for each system-library module map directory.
        var moduleMapDirs = Set<String>()
        for file in inputs.moduleMapFiles {
            let dir = (file.filePath as NSString).deletingLastPathComponent
            if !dir.isEmpty { moduleMapDirs.insert(dir) }
        }
        for dir in moduleMapDirs.sorted() {
            arguments.append("-I"); arguments.append(dir)
        }

        for sourceFile in inputs.sourceFiles {
            arguments.append(sourceFile.filePath)
        }

        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolExecutorRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        let result = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputs.sourceFiles + inputs.moduleFiles + inputs.moduleMapFiles,
            expectedOutputFileNames: [objectOutput, moduleOutput, interfaceOutput])

        let objectBytes = result.outputFiles[objectOutput] ?? []
        let moduleBytes = result.outputFiles[moduleOutput] ?? []
        let interfaceBytes = result.outputFiles[interfaceOutput] ?? []

        guard result.exitCode == 0 else {
            let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try result.errorOutput.intern()))
            return .init(outputObject: error,
                         outputModule: error,
                         outputInterface: error,
                         infoLog: .value(try result.infoOutput.intern()),
                         inputSourceFilesExpectations: inputSourceFilesExpectations,
                         inputModuleMapFilesExpectations: inputModuleMapFilesExpectations)
        }

        return .init(outputObject:    .value(try objectBytes.intern()),
                     outputModule:    .value(try moduleBytes.intern()),
                     outputInterface: .value(try interfaceBytes.intern()),
                     infoLog:         .value(try result.infoOutput.intern()),
                     inputSourceFilesExpectations: inputSourceFilesExpectations,
                     inputModuleMapFilesExpectations: inputModuleMapFilesExpectations)
    }

    private func process(inputs: SwiftCompilerToolInputs) throws -> SwiftCompilerToolOutputs {
        let inputSourceFilesExpectations    = buildInputSourceFilesExpectations(folderManifests: inputs.inputFolderManifests)
        let inputModuleMapFilesExpectations = buildInputModuleMapFilesExpectations(moduleMapFolderManifests: inputs.moduleMapFolderManifests)
        do {
            return try compile(inputs: inputs,
                               inputSourceFilesExpectations: inputSourceFilesExpectations,
                               inputModuleMapFilesExpectations: inputModuleMapFilesExpectations)
        } catch {
            let errorNodeValue = NodeValue.noValue(reason: .error(messageDataObjectHash: try error.localizedDescription.intern()))
            return .init(outputObject: errorNodeValue,
                         outputModule: errorNodeValue,
                         outputInterface: errorNodeValue,
                         infoLog: .value(""),   // empty content never reaches the store
                         inputSourceFilesExpectations: inputSourceFilesExpectations,
                         inputModuleMapFilesExpectations: inputModuleMapFilesExpectations)
        }
    }
}
