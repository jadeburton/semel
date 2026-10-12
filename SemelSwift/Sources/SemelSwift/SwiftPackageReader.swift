// SwiftPackageReader.swift
// semel
//
// Reads a Swift package manifest by shelling out to `swift package dump-package`
// and emits the resulting JSON on its output wire.
//
// Wire a StaticFile(path: 'path/to/Package.swift').output to the `packageFile` input port
// and the package folder's manifest to `packageFolder`. The node re-runs whenever either
// changes, and whenever a version-specific manifest the folder holds does.
//
// `swift package dump-package` writes its JSON to stdout.  LocalFileSystemTool
// forwards stdout to the `logMessage` callback, so we capture it there rather
// than via `expectedOutputFileNames`.
//
// The manifests are laid in the sandbox at their wire keys, as `ToolSandbox` lays every
// input, and the subcommand is pointed at their folder, so a `..` the manifest names is a
// folder of the name it has in the input file system.

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

    /// Where this node's settings live in a config file: `swift.packageReader.<key>`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "SwiftPackageReader")
}

// MARK: - Node

struct SwiftPackageReader: Node {
    public static let kind: UInt = 23

    /// 2: several wires on a one-wire port are an error naming them, where one was read
    /// (B-141).
    /// 3: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    /// 4: the manifest is laid at its path in the input file system, so a `..` dependency
    /// is named after the folder it is; a path dependency naming an ancestor folder itself
    /// is published relative to the package, as one below an ancestor always was; and the
    /// package's version-specific manifests are laid beside `Package.swift`, so the tool
    /// reads the one SwiftPM would (B-80).
    public static let implementationVersion = 4

    // MARK: Ports

    static let configuration = "configuration"
    /// Wire StaticFile(path: 'path/to/Package.swift').output here.
    /// Triggers re-run whenever Package.swift content changes.
    static let packageFile   = "packageFile"
    /// The manifest of the package's folder: which version-specific manifests sit beside
    /// `Package.swift`, which the node asks for itself on `versionSpecificManifests`.
    static let packageFolder = "packageFolder"
    /// Every `Package@swift-<version>.swift` the folder holds, keyed by path.
    static let versionSpecificManifests = "versionSpecificManifests"
    /// JSON output from `swift package dump-package`.
    static let packageJSON   = "packageJSON"
    static let infoLog       = "infoLog"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(configuration), .required(packageFile), .required(packageFolder),
                     .dynamic(versionSpecificManifests)],
        outputPorts: [packageJSON, infoLog]
    )

    // MARK: - Version-specific manifests

    /// Whether `fileName` is a manifest SwiftPM reads in place of `Package.swift` under a
    /// toolchain at least as new as the version it names: `Package@swift-6.swift`,
    /// `Package@swift-5.9.swift`, `Package@swift-5.9.1.swift`, the pattern SwiftPM matches.
    ///
    /// Which of them is read is not decided here. SwiftPM takes the one naming the
    /// toolchain's own version exactly; failing that, the newest naming an older version,
    /// and that one only when its `swift-tools-version` line is newer than
    /// `Package.swift`'s — so a `Package@swift-5.7.swift` kept for older toolchains is not
    /// read by 6.3 when `Package.swift` declares 5.9. A choice made from the names alone
    /// would read that one, so every candidate is laid beside `Package.swift` and the tool
    /// the configuration names decides, as it does on disk; its fingerprint is in the key.
    static func isVersionSpecificManifest(_ fileName: String) -> Bool {
        fileName.range(of: #"^Package@swift-[0-9]+(\.[0-9]+){0,2}\.swift$"#, options: .regularExpression) != nil
    }

    /// The version-specific manifests a folder holds, as the specs this node asks for them
    /// by, keyed by path: pushed files only, since a product the graph made is no manifest.
    static func versionSpecificManifestSpecs(in folder: FolderManifest) -> [String: GraphSpecNode] {
        var specs: [String: GraphSpecNode] = [:]
        for entry in folder.entries where !entry.isFolder && entry.isPinned && isVersionSpecificManifest(entry.name) {
            let path = "\(folder.baseFolderPath)/\(entry.name)"
            specs[path] = .staticFile(at: path)
        }
        return specs
    }

    // MARK: - Inputs / Outputs

    struct SwiftPackageReaderInputs {
        let configuration: SwiftPackageReaderConfiguration
        /// Every manifest laid in the sandbox, at its path in the input file system:
        /// `Package.swift` and each version-specific one the folder holds.
        let manifestFiles: [FileNameAndContent]
        /// The folder holding them, which the subcommand is pointed at.
        let packageFolderPath: String
        /// What the node asks for on `versionSpecificManifests`, on every output.
        let demands: [String: GraphSpecNode]
        /// The version-specific manifests the folder holds that have no value yet.
        let awaited: [String]

        init(input: ProcessInput) throws {
            let configString = try input.onlyWire(onRequiredPort: SwiftPackageReader.configuration)
                .value.expectValue().resolveAsString()

            configuration = try .init(properties: [String: String](plainText: configString))

            let packageFileWire = try input.onlyWire(onRequiredPort: SwiftPackageReader.packageFile)
            let folderWire      = try input.onlyWire(onRequiredPort: SwiftPackageReader.packageFolder)
            let folderJSON      = try folderWire.value.expectValue().resolveAsString()
            guard let folder = try? TypeRegistry.decode(encodedJSON: folderJSON) as? FolderManifest else {
                throw ErrorCondition.valueUnreadable(form: .folderManifest, port: SwiftPackageReader.packageFolder,
                                                     wire: folderWire.key)
            }

            packageFolderPath = folder.baseFolderPath
            demands = SwiftPackageReader.versionSpecificManifestSpecs(in: folder)
            let received = input.inputValues[SwiftPackageReader.versionSpecificManifests] ?? [:]
            // Beside the others in the folder whatever its wire is called: the subcommand
            // reads the folder, not a file.
            var files = [FileNameAndContent(filePath: "\(packageFolderPath)/Package.swift",
                                            hash: try packageFileWire.value.expectValue())]
            var awaited: [String] = []
            for path in demands.keys.sorted() {
                guard case .value(let hash) = received[path] else {
                    awaited.append(path)
                    continue
                }
                files.append(FileNameAndContent(filePath: path, hash: hash))
            }
            manifestFiles = files
            self.awaited  = awaited
        }
    }

    struct SwiftPackageReaderOutputs {
        let packageJSON: NodeValue
        let infoLog:     NodeValue
        let demands:     [String: GraphSpecNode]

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftPackageReader.packageJSON: packageJSON,
                                 SwiftPackageReader.infoLog: infoLog],
                  inputWireSpecs: [SwiftPackageReader.versionSpecificManifests: demands])
        }
    }

    // MARK: - Processing

    /// The binary behind the tool version the configuration names: two builds of one
    /// version can dump a manifest differently, and only a fingerprint of the binary tells
    /// them apart (B-17).
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try toolBinaryCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }

    /// A manifest's failure belongs to its package, named by the folder that holds it.
    public func errorSubject(input: ProcessInput?) -> ErrorDocument.Subject? {
        input?.inputValues[Self.packageFile]?.keys.min().map(Self.subject(ofPackageFileAt:))
    }

    /// The package a `Package.swift` at `path` is, by its folder's name: the manifest that
    /// would say its name is what failed to be read.
    static func subject(ofPackageFileAt path: String) -> ErrorDocument.Subject {
        let folder = Path(path).deletingLastComponent ?? Path(path)
        return .package(name: folder.lastComponent ?? path)
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    func process(inputs: SwiftPackageReaderInputs) throws -> SwiftPackageReaderOutputs {
        let subject = Self.subject(ofPackageFileAt: inputs.manifestFiles[0].filePath)
        guard inputs.awaited.isEmpty else {
            let pending = try ErrorDocument.engine(.inputsWithoutValue(kind: .versionSpecificManifests, paths: inputs.awaited),
                                                   subject: subject).published()
            return .init(packageJSON: pending, infoLog: pending, demands: inputs.demands)
        }

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor,
                                                        namespace:  SwiftPackageReaderConfiguration.settingNamespace)

        var jsonOutput   = ""
        var stderrOutput = ""

        let result = try tool.execute(
            arguments: ["package", "dump-package", "--package-path", inputs.packageFolderPath],
            environment: [:],
            inputFiles: inputs.manifestFiles,
            expectedOutputFileNames: [],   // JSON is emitted to stdout, not a file
            expectedOutputFolders: [],
            output: .init(
                logError:   { message in stderrOutput += message },
                logMessage: { message in jsonOutput += message },  // stdout → JSON
                write:      { _, _ in }))

        guard result.exitCode == 0 else {
            return .init(
                packageJSON: try ErrorDocument.tool(text: stderrOutput, tool: "swift package dump-package", status: result.exitCode,
                                                    subject: subject).published(),
                infoLog: .value(try stderrOutput.intern()),
                demands: inputs.demands)
        }

        guard !jsonOutput.isEmpty else {
            return .init(
                packageJSON: try ErrorDocument.engine(.toolWroteNothing(tool: "swift package dump-package", status: result.exitCode,
                                                                        paths: []),
                                                      subject: subject).published(),
                infoLog: .value(try stderrOutput.intern()),
                demands: inputs.demands)
        }

        // resolvedSandboxPath is symlink-resolved, captured before the sandbox was deleted,
        // so a `/private/var/…` path SPM printed matches it.
        jsonOutput = Self.relativizingPaths(in: jsonOutput,
                                            packageFolder: result.resolvedSandboxPath + "/" + inputs.packageFolderPath)

        return .init(
            packageJSON: .value(try jsonOutput.intern()),
            infoLog: .value(try stderrOutput.intern()),
            demands: inputs.demands)
    }

    /// Parses `jsonOutput` and replaces every string value naming the package's folder
    /// in the sandbox, `packageFolder`, or a path at or below one of its ancestors, with
    /// the path relative to the package, then re-encodes to JSON: dump-package makes a
    /// path dependency absolute, and the sandbox's name is in no output. An ancestor named
    /// exactly — a manifest's `.package(path: "..")` — is `..`, which the converter resolves
    /// against the package's folder like any other relative path. Uses
    /// `JSONSerialization` so all escape sequences are handled correctly by the standard
    /// library.
    static func relativizingPaths(in jsonOutput: String, packageFolder: String) -> String {
        // Most specific first, so the longest prefix matches: the package's folder, then
        // each ancestor up to the root, each with its path relative to the package.
        var ancestors: [(absolute: String, relative: String)] = []
        var current = Path(packageFolder)
        var upward  = ""
        while !current.isEmpty {
            ancestors.append(("/" + current.string, upward))
            upward += "../"
            guard let parent = current.deletingLastComponent else {
                break
            }
            current = parent
        }

        func mapPath(_ string: String) -> String {
            for (absolute, relative) in ancestors {
                if string == absolute {
                    return relative.isEmpty ? "." : String(relative.dropLast())
                }
                if string.hasPrefix(absolute + "/") {
                    return relative + string.dropFirst(absolute.count + 1)
                }
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
