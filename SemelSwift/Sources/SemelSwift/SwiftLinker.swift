// SwiftLinker.swift
// semel
//
// Swift linker stage: links one or more .o object files into a final
// executable, dynamic library or static archive using `swiftc` as the driver.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

/// The artifact a link produces. A formula literal, like `outputName`: it says what the
/// product *is*, and no config file may change that.
enum SwiftLinkage: String, CaseIterable {
    case executable
    /// `lib<name>.dylib`, via `-emit-library`.
    case dynamicLibrary
    /// `lib<name>.a`, via `-emit-library -static`, which has swiftc drive libtool and
    /// write a plain `ar` archive — so the linker stays one tool.
    case staticArchive
}

struct SwiftLinkerConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    /// Which SDK, as `xcrun --sdk` names it: `macosx` unless declared. See SwiftCompiler.
    let sdk: String
    /// The `-target` triple; nil passes none, which is the host.
    let target: String?
    /// Declared in semel.config; nil means whatever this machine has.
    let sdkVersion: String?
    let linkage: SwiftLinkage
    let outputName: String

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        outputName = required.value("outputName")
        let linkageName = required.value("linkage")
        try required.check()

        // Three forms and no default, so a bad spelling is an error, not an executable.
        guard let linkage = SwiftLinkage(rawValue: linkageName) else {
            let accepted = SwiftLinkage.allCases.map(\.rawValue).joined(separator: ", ")
            throw NodeError.other(message: "linkage '\(linkageName)' is not one of: \(accepted)")
        }
        self.linkage = linkage

        arguments = []
        environment = [:]
        sdk = properties["sdk"] ?? defaultSDKName
        target = properties["target"]
        sdkVersion = properties["sdkVersion"]
    }

    /// Where this node's settings live in a config file: `swift.linker.sdkVersion`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "SwiftLinker")
}

// MARK: - Node

struct SwiftLinker: Node {
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
    /// published at the default 0644 and will not run. Same arrangement as ClangLinker.
    static let fileMetadata = FileMetadata.portName

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .required(configuration),
            .required(input),
            .optional(libraryFolders),
            .dynamic(libraries),
        ],
        outputPorts: [output, infoLog, fileMetadata]
    )


    // MARK: Processing

    struct SwiftLinkerInputs {
        let configuration: SwiftLinkerConfiguration
        let objectFiles: [FileNameAndContent]
        let libraryFiles: [FileNameAndContent]
        let libraryFolderManifests: [(String, FolderManifest)]

        init(input: ProcessInput) throws {
            let configurationString = try input.inputValues[SwiftLinker.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = try .init(properties: [String: String](plainText: configurationString))

            // Sorted: these go straight onto the command line, and Swift Dictionary
            // iteration order changes from one process to the next.
            var objectFiles: [FileNameAndContent] = []

            for (fileName, nodeValue) in input.inputValues[SwiftLinker.input]!.sorted(by: { $0.key < $1.key }) {
                objectFiles.append(.init(filePath: fileName, hash: try nodeValue.expectValue()))
            }

            self.objectFiles = objectFiles

            var libraryFiles: [FileNameAndContent] = []

            for (fileName, nodeValue) in input.inputValues[SwiftLinker.libraries]!.sorted(by: { $0.key < $1.key }) {
                libraryFiles.append(.init(filePath: fileName, hash: try nodeValue.expectValue()))
            }

            self.libraryFiles = libraryFiles

            var libraryFolderManifests = [(String, FolderManifest)]()

            for (key, value) in (input.inputValues[SwiftLinker.libraryFolders] ?? [:]).sorted(by: { $0.key < $1.key }) {

                guard let jsonString = try? value.expectValue().resolveAsString(),
                      let manifest = try? TypeRegistry.decode(encodedJSON: jsonString) as? FolderManifest else {
                    continue
                }

                libraryFolderManifests.append((key, manifest))
            }

            self.libraryFolderManifests = libraryFolderManifests
        }
    }

    struct SwiftLinkerOutputs {
        let output: NodeValue
        let infoLog: NodeValue
        let fileMetadata: NodeValue
        let librariesSpecs: [String: String]

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftLinker.output: output,
                                 SwiftLinker.infoLog: infoLog,
                                 SwiftLinker.fileMetadata: fileMetadata],
                  inputWireSpecs: [SwiftLinker.libraries: librariesSpecs])
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
    private func buildLibrariesSpecs(libraryFolderManifests: [(String, FolderManifest)]) -> [String: String] {
        var result: [String: String] = [:]

        for (_, manifest) in libraryFolderManifests {
            for entry in manifest.entries where entry.isPinned && !entry.isFolder && entry.name.hasSuffix(".a") {
                let fullPath = (Path(manifest.baseFolderPath) / entry.name).string
                result[fullPath] = "StaticFile(path: '\(fullPath)').output"
            }
        }

        return result
    }

    func process(inputs: SwiftLinkerInputs) throws -> SwiftLinkerOutputs {

        let librariesSpecs = buildLibrariesSpecs(libraryFolderManifests: inputs.libraryFolderManifests)

        let outputName = inputs.configuration.outputName

        var arguments = [String]()

        switch inputs.configuration.linkage {
        case .executable:     break
        case .dynamicLibrary: arguments.append("-emit-library")
        case .staticArchive:  arguments.append(contentsOf: ["-emit-library", "-static"])
        }

        // Pass the SDK path so swiftc's linker driver can find libSystem and
        // other system libraries when invoked directly (outside of xcodebuild).
        let sdk = inputs.configuration.sdk
        try verifySDKVersion(inputs.configuration.sdkVersion, sdk: sdk)

        guard let sdkPath = resolveSDKPath(sdk: sdk) else {
            throw NodeError.other(message: "no SDK named \(sdk) could be found on this machine "
                                         + "(swift.linker.sdk names it as `xcrun --sdk` would)")
        }
        arguments.append("-sdk")
        arguments.append(sdkPath)

        if let target = inputs.configuration.target {
            arguments.append("-target")
            arguments.append(target)
        }

        for objectFile in inputs.objectFiles {
            arguments.append(objectFile.filePath)
        }

        for libraryFile in inputs.libraryFiles {
            arguments.append(libraryFile.filePath)
        }

        arguments.append("-o"); arguments.append(outputName)
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var inputFiles: [FileNameAndContent] = []
        inputFiles.append(contentsOf: inputs.objectFiles)
        inputFiles.append(contentsOf: inputs.libraryFiles)

        let result = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputFiles,
            expectedOutputFileNames: [outputName])

        // A library is loaded or linked, not run, so only an executable needs the x bits.
        let mode: UInt16 = inputs.configuration.linkage == .executable ? FileMetadata.executableMode : FileMetadata.defaultMode
        let metadataJSON = (try? FileMetadata(mode: mode).jsonString()) ?? "{}"

        return .init(output: try result.asOutputNodeValue(),
                     infoLog: .value(try result.infoOutput.intern()),
                     fileMetadata: .value(try metadataJSON.intern()),
                     librariesSpecs: librariesSpecs)
    }
}
