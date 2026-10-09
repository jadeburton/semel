// ClangLinker.swift
// semel
//
// Clang linker stage: links one or more .o object files (and optional .dylib
// libraries) into a final output binary.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct ClangLinkerConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    let dynamicLibrary: Bool
    let target: String  // e.g. "arm64-apple-macos14.0"
    let sdkPath: String?
    /// True when the configuration declares `cxxStandard` — the same key the compiler reads
    /// (B-48) — or `cxxRuntime`, indicating a C++ link that needs `-lc++` beside `-lSystem`
    /// even when no object file is recognisably C++, such as C objects linked against a
    /// C++ archive.
    let cxx: Bool
    /// `frameworks` and `libraries`, each passed as `-framework` and `-l` (B-55).
    let requirements: LinkRequirements

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        target = required.value("target")
        try required.check()

        arguments = clangArguments(properties)
        environment = [:]
        dynamicLibrary = properties["dynamicLibrary"] == "true"
        sdkPath = properties["sdkPath"]
        requirements = LinkRequirements(properties: properties)
        cxx = properties["cxxStandard"] != nil || requirements.cxxRuntime
    }

    /// Where this node's settings live in a config file: `clang.linker.<key>`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "ClangLinker")
}

// MARK: - Node

public struct ClangLinker: Node {
    public static let kind: UInt = 18

    /// 2: passes the `frameworks` and `libraries` its settings state (B-55).
    /// 3: several wires on `configuration` are an error naming them, where one was taken
    /// (B-141).
    /// 4: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    /// 5: the fingerprint of the SDK tree at `sdkPath` is in the key (B-47).
    public static let implementationVersion = 5

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
            .required(input, .many),
            .optional(libraries, .many),
        ],
        outputPorts: [output, infoLog, fileMetadata]
    )

    // MARK: Processing

    struct ClangLinkerInputs {
        let configuration: ClangLinkerConfiguration
        let libraryFiles: [FileNameAndContent]
        let objectFiles: [FileNameAndContent]

        init(input: ProcessInput) throws {
            let configurationString = try input.onlyWire(onRequiredPort: ClangCompiler.configuration).value.expectValue().resolveAsString()
            configuration = try .init(properties: [String: String](plainText: configurationString))

            let inputValues = try input.wires(on: ClangLinker.input)
            let libraryValues = try input.wires(on: ClangLinker.libraries)

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

    struct ClangLinkerOutputs {
        let output: NodeValue
        let infoLog: NodeValue
        let fileMetadata: NodeValue

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [ClangLinker.output: output,
                                 ClangLinker.infoLog: infoLog,
                                 ClangLinker.fileMetadata: fileMetadata],
                  inputWireSpecs: [:])
        }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    func process(inputs: ClangLinkerInputs) throws -> ClangLinkerOutputs {

        var arguments = [String]()
        // The arguments built from settings, collected as they are appended so a linker
        // diagnostic about one of them can name the key behind it (B-98).
        var settings = [SettingArgument]()
        let namespace = ClangLinkerConfiguration.settingNamespace

        arguments.append("-target");
        arguments.append(inputs.configuration.target)
        settings.append(.clangTarget(key: "\(namespace).target", value: inputs.configuration.target))

        arguments.append("-L"); arguments.append(".")

        if let sdkPath = inputs.configuration.sdkPath {
            let searchPath = sdkPath + "/usr/lib"
            arguments.append("-L"); arguments.append(searchPath)
            settings.append(.clangLibrarySearchPath(key: "\(namespace).sdkPath",
                                                    value: sdkPath,
                                                    searchPath: searchPath))
        }

        arguments.append("-lSystem")

        // Link against libc++ if any object file was compiled from C++ or Objective-C++
        // source, or if the configuration declares a C++ standard (`cxxStandard`).
        let hasCxxObjects = inputs.objectFiles.contains {
            ClangPreprocessor.language(for: $0.filePath).hasSuffix("++")
        }

        if hasCxxObjects || inputs.configuration.cxx {
            arguments.append("-lc++")
        }

        arguments.append("-nostdlib")

        if inputs.configuration.dynamicLibrary {
            arguments.append("-dynamiclib")
        }

        // The debug map (N_OSO) names each object file. Prefixed with the working
        // directory it is the object's sandbox-relative path, not the sandbox's own name.
        arguments.append(contentsOf: ["-Xlinker", "-oso_prefix", "-Xlinker", "."])

        for objectFile in inputs.objectFiles {
            arguments.append(objectFile.filePath)
        }

        for libraryFile in inputs.libraryFiles {
            arguments.append(libraryFile.filePath)
        }

        // `-nostdlib` and no sysroot: a framework is found where the SDK keeps it, as
        // `-lSystem` is found under the SDK's `usr/lib` above.
        let requirements = inputs.configuration.requirements
        if let sdkPath = inputs.configuration.sdkPath, !requirements.frameworks.isEmpty {
            let frameworksPath = sdkPath + "/System/Library/Frameworks"
            arguments.append("-F"); arguments.append(frameworksPath)
        }
        arguments.append(contentsOf: requirements.frameworkAndLibraryArguments)

        arguments.append("-o"); arguments.append("output.dylib")
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor,
                                                        namespace:  ClangLinkerConfiguration.settingNamespace)

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

        return .init(output: try result.asOutputNodeValue(tool: "clang", subject: nil, settings: settings),
                     infoLog: .value(try result.infoOutput.intern()),
                     fileMetadata: metadataValue)
    }
}
