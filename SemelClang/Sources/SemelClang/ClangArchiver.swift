// ClangArchiver.swift
// SemelClang
//
// Static archive stage: puts object files into a `.a` with `libtool -static`. Clang itself
// writes no archive — `swiftc -emit-library -static` drives libtool underneath — so this
// is the one node in the package that runs a tool other than clang, under a namespace of
// its own that `semel-clang` writes like the others (B-79).

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct ClangArchiverConfiguration {
    let toolDescriptor: ToolDescriptor
    let environment: [String: String]

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        try required.check()

        // libtool zeroes a member's timestamp, uid and gid when it inherits ZERO_AR_DATE=1;
        // otherwise the `ar` header carries the wall clock and two cold builds of the same
        // objects produce different bytes.
        environment = ["ZERO_AR_DATE": "1"]
    }

    /// Where this node's settings live in a config file: `clang.archiver.<key>`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "ClangArchiver")
}

// MARK: - Node

public struct ClangArchiver: Node {
    public static let kind: UInt = 38

    // MARK: Ports

    static let configuration = "configuration"
    static let input = "objectFiles"
    static let output = "output"
    static let infoLog = "infoLog"
    /// Declared so `ProjectBuilder` wires the archive's Unix mode into its `OutputFile`,
    /// as for the linker; an archive is linked, not run, so the mode is the default one.
    static let fileMetadata = FileMetadata.portName

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(configuration), .required(input)],
        outputPorts: [output, infoLog, fileMetadata]
    )

    // MARK: Processing

    struct ClangArchiverInputs {
        let configuration: ClangArchiverConfiguration
        let objectFiles: [FileNameAndContent]

        init(input: ProcessInput) throws {
            let configurationString = try input.firstWire(onRequiredPort: ClangArchiver.configuration).value.expectValue().resolveAsString()
            configuration = try .init(properties: [String: String](plainText: configurationString))

            // Sorted, not straight out of the dictionary: the members' order is the
            // archive's bytes, and a Swift Dictionary iterates differently per process.
            var objectFiles: [FileNameAndContent] = []
            for (objectFileName, nodeValue) in try input.wires(on: ClangArchiver.input).sorted(by: { $0.key < $1.key }) {
                objectFiles.append(.init(filePath: objectFileName, hash: try nodeValue.expectValue()))
            }
            self.objectFiles = objectFiles
        }
    }

    struct ClangArchiverOutputs {
        let output: NodeValue
        let infoLog: NodeValue
        let fileMetadata: NodeValue

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [ClangArchiver.output: output,
                                 ClangArchiver.infoLog: infoLog,
                                 ClangArchiver.fileMetadata: fileMetadata],
                  inputWireSpecs: [:])
        }
    }

    /// The binary behind the tool version the configuration names, as for the linker
    /// (B-17): two libtools reporting one version may still write different archives.
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try toolBinaryCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    static let outputFileName = "output.a"

    func process(inputs: ClangArchiverInputs) throws -> ClangArchiverOutputs {
        var arguments = ["-static", "-o", Self.outputFileName]
        for objectFile in inputs.objectFiles {
            arguments.append(objectFile.filePath)
        }

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor,
                                                        namespace:  ClangArchiverConfiguration.settingNamespace)

        let result = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputs.objectFiles,
            expectedOutputFileNames: [Self.outputFileName])

        let metadataJSON = (try? FileMetadata(mode: FileMetadata.defaultMode).jsonString()) ?? "{}"

        return .init(output: try result.asOutputNodeValue(tool: "libtool"),
                     infoLog: .value(try result.infoOutput.intern()),
                     fileMetadata: .value(try metadataJSON.intern()))
    }
}
