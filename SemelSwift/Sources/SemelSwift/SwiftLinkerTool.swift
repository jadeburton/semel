// SwiftLinkerTool.swift
// build_system
//
// Swift linker stage: links one or more .o object files into a final
// executable or dynamic library using `swiftc` as the driver.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

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
    public static let kind: UInt = 21

    // MARK: Ports

    static let configuration = "configuration"
    static let input = "input"
    /// Dynamic port — one wire per static archive discovered through `libraryFolders`.
    static let libraries = "libraries"
    /// Folder manifests for the system-library targets this product reaches, directly or
    /// transitively.  A user drops a vendored `.a` beside the module map to have it linked
    /// in; with no archive present the modulemap's `link "sqlite3"` resolves against the
    /// SDK and the product depends on the system copy, which is the pre-existing default.
    static let libraryFolders = "libraryFolders"
    static let output = "output"
    static let infoLog = "infoLog"
    /// Declaring this port is what makes ProjectBuilder wire the linked file's Unix mode
    /// into its OutputFile wrapper, so `cp` can chmod it. Without it an executable is
    /// published at the default 0644 and will not run. Same arrangement as ClangLinkerTool.
    static let fileMetadata = FileMetadata.portName

    public var embeddedNode: Node

    public init(thisNode: Node) throws {
        embeddedNode = thisNode
    }

    public static let descriptor = NodeFunctionDescriptor(
        inputPorts: [
            .required(configuration),
            .required(input),
            .optional(libraryFolders),
            .dynamic(libraries),
        ],
        outputPorts: [output, infoLog, fileMetadata]
    )


    // MARK: Processing

    struct SwiftLinkerToolInputs {
        let configuration: SwiftLinkerToolConfiguration
        let objectFiles: [FileNameAndContent]
        let libraryFiles: [FileNameAndContent]
        let libraryFolderManifests: [(String, FolderManifest)]

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

            var libraryFolderManifests = [(String, FolderManifest)]()
            for (key, value) in (input.inputValues[SwiftLinkerTool.libraryFolders] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let jsonString = try? value.expectValue().resolveAsString(),
                      let manifest = try? PolyFactory.decode(encodedJSON: jsonString) as? FolderManifest
                else { continue }
                libraryFolderManifests.append((key, manifest))
            }
            self.libraryFolderManifests = libraryFolderManifests
        }
    }

    struct SwiftLinkerToolOutputs {
        let output: NodeValue
        let infoLog: NodeValue
        let fileMetadata: NodeValue
        let librariesExpectations: [String: String]

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftLinkerTool.output: output,
                                 SwiftLinkerTool.infoLog: infoLog,
                                 SwiftLinkerTool.fileMetadata: fileMetadata],
                  inputWireExpectations: [SwiftLinkerTool.libraries: librariesExpectations])
        }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    /// One wire per static archive sitting in a system library's folder.
    ///
    /// Only `.a` files: the module map, the shim and any vendored header in that folder
    /// belong to the compile, and handing them to the linker would be an error rather
    /// than merely noise.  A folder with no archive yields nothing, which is the
    /// "link against the system library" default.
    private func buildLibrariesExpectations(libraryFolderManifests: [(String, FolderManifest)]) -> [String: String] {
        var result: [String: String] = [:]
        for (_, manifest) in libraryFolderManifests {
            for entry in manifest.entries where entry.isPinned && !entry.isFolder && entry.name.hasSuffix(".a") {
                let fullPath = (Path(manifest.baseFolderPath) / entry.name).string
                result[fullPath] = "StaticFile(path: '\(fullPath)').output"
            }
        }
        return result
    }

    func process(inputs: SwiftLinkerToolInputs) throws -> SwiftLinkerToolOutputs {

        let librariesExpectations = buildLibrariesExpectations(libraryFolderManifests: inputs.libraryFolderManifests)

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
                     fileMetadata: .value(try metadataJSON.intern()),
                     librariesExpectations: librariesExpectations)
    }
}
