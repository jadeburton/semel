// SwiftPackageReader.swift
// semel
//
// Reads a Swift package manifest by shelling out to `swift package dump-package`
// and emits the resulting JSON on its output wire.
//
// Wire a StaticFile(path: 'path/to/Package.swift').output to the `packageFile`
// input port.  The node re-runs automatically whenever Package.swift changes.
//
// `swift package dump-package` writes its JSON to stdout.  LocalFileSystemTool
// forwards stdout to the `logMessage` callback, so we capture it there rather
// than via `expectedOutputFileNames`.
//
// Package.swift is placed at the sandbox root (filePath = "Package.swift")
// regardless of the wire key's full path, because that is where the SPM
// subcommand looks for it in the working directory.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct SwiftPackageReaderConfiguration {
    let toolDescriptor: ToolDescriptor

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        try required.check()
    }

    func asDictionary() -> [String: String] {
        ["toolDescriptor.name":          toolDescriptor.name,
         "toolDescriptor.version":       toolDescriptor.version,
         "toolDescriptor.platform":      toolDescriptor.platform,
         "toolDescriptor.architecture":  toolDescriptor.architecture,
         "toolDescriptor.recursiveHash": toolDescriptor.recursiveHash ?? ""]
    }

    /// Where this node's settings live in a config file: `swift.packageReader.<key>`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "SwiftPackageReader")
}

// MARK: - Node

struct SwiftPackageReader: Node {
    public static let kind: UInt = 23

    // MARK: Ports

    static let configuration = "configuration"
    /// Wire StaticFile(path: 'path/to/Package.swift').output here.
    /// Triggers re-run whenever Package.swift content changes.
    static let packageFile   = "packageFile"
    /// JSON output from `swift package dump-package`.
    static let packageJSON   = "packageJSON"
    static let infoLog       = "infoLog"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(configuration), .required(packageFile)],
        outputPorts: [packageJSON, infoLog]
    )

    // MARK: - Inputs / Outputs

    struct SwiftPackageReaderInputs {
        let configuration: SwiftPackageReaderConfiguration
        let packageFile: FileNameAndContent

        init(input: ProcessInput) throws {
            let configString = try input.inputValues[SwiftPackageReader.configuration]!
                .values.first!.expectValue().resolveAsString()

            configuration = try .init(properties: [String: String](plainText: configString))

            let packageFileNodeValues = input.inputValues[SwiftPackageReader.packageFile]!.values.first!

            let fileEntry = try packageFileNodeValues.expectValue()

            // Place the file at the sandbox root so `swift package dump-package`
            // finds it in the working directory, regardless of the wire key's full path.
            packageFile = FileNameAndContent(filePath: "Package.swift", hash: fileEntry)
        }
    }

    struct SwiftPackageReaderOutputs {
        let packageJSON: NodeValue
        let infoLog:     NodeValue

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftPackageReader.packageJSON: packageJSON,
                                 SwiftPackageReader.infoLog: infoLog],
                  inputWireSpecs: [:])
        }
    }

    // MARK: - Processing

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    func process(inputs: SwiftPackageReaderInputs) throws -> SwiftPackageReaderOutputs {
        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var jsonOutput   = ""
        var stderrOutput = ""

        let result = try tool.execute(
            arguments: ["package", "dump-package"],
            environment: [:],
            inputFiles: [inputs.packageFile],
            expectedOutputFileNames: [],   // JSON is emitted to stdout, not a file
            output: .init(
                logError:   { message in stderrOutput += message },
                logMessage: { message in jsonOutput += message },  // stdout → JSON
                write:      { _, _ in }))

        guard result.exitCode == 0 else {
            return .init(
                packageJSON: .noValue(reason: .error(messageDataObjectHash: try "swift package dump-package failed:\n\(stderrOutput)".intern())),
                infoLog: .value(try stderrOutput.intern()))
        }

        guard !jsonOutput.isEmpty else {
            return .init(
                packageJSON: .noValue(reason: .error(messageDataObjectHash: try "SwiftPackageReader: no output from swift package dump-package".intern())),
                infoLog: .value(try stderrOutput.intern()))
        }

        // sandboxPathUsed is already symlink-resolved (captured before the sandbox
        // directory was deleted, so /var -> /private/var is followed correctly).
        jsonOutput = stripOutSandboxPaths(sandboxPath: result.sandboxPathUsed, jsonOutput: jsonOutput)

        return .init(
            packageJSON: .value(try jsonOutput.intern()),
            infoLog: .value(try stderrOutput.intern()))
    }

    /// Parses `jsonOutput`, replaces every string value that starts with a
    /// sandbox-rooted absolute path with its relative equivalent, then
    /// re-encodes to JSON. Uses `JSONSerialization` so all escape sequences
    /// are handled correctly by the standard library.
    private func stripOutSandboxPaths(sandboxPath: String, jsonOutput: String) -> String {
        // Build priority-ordered ancestor table (longest / most-specific first).
        var ancestors: [(abs: String, rel: String)] = [(sandboxPath, "")]
        var current = sandboxPath
        var upPrefix = "../"

        for _ in 0..<6 {
            guard let parent = Path(current).deletingLastComponent else { break }
            current = "/" + parent.string
            ancestors.append((current, upPrefix))
            upPrefix = "../" + upPrefix
        }

        func mapPath(_ string: String) -> String {
            for (abs, rel) in ancestors where string.hasPrefix(abs + "/") {
                return rel + string.dropFirst(abs.count + 1)
            }
            return string
        }

        func transformValue(_ value: Any) -> Any {
            switch value {
            case let string as String:       return mapPath(string)
            case let array as [Any]:         return array.map { transformValue($0) }
            case let dict as [String: Any]:  return dict.mapValues { transformValue($0) }
            default:                         return value
            }
        }

        guard let inputData = jsonOutput.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: inputData),
              let outputData = try? JSONSerialization.data(withJSONObject: transformValue(parsed),
                                                          options: [.sortedKeys]),
              let result = String(data: outputData, encoding: .utf8) else {

            return jsonOutput
        }

        return result
    }
}
