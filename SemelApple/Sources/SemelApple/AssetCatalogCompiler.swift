//
//  AssetCatalogCompiler.swift
//  SemelApple
//
//  Runs `actool` over one or more asset catalogs — `.xcassets`, and the `.icon` folders
//  Icon Composer writes — for a platform. What comes out is decided by the catalogs: an
//  `Assets.car`, and one PNG per app-icon size the platform wants, so the result is a
//  tree, not a file. The partial Info.plist actool writes (the icon keys) is a value of
//  its own, for `InfoPlistBuilder` to merge.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct AssetCatalogCompilerConfiguration {
    let toolDescriptor: ToolDescriptor
    /// As `actool --platform` names it: `iphonesimulator`, `iphoneos`, `macosx`.
    let platform: String
    /// `18.0`: what decides which icon sizes and image variants are compiled.
    let minimumDeploymentTarget: String
    /// `iphone`, `ipad`, `mac`; one `--target-device` each.
    let targetDevices: [String]
    /// The app icon set to compile and to name in the partial Info.plist, if any. A
    /// formula literal rather than a config setting: it says what the product *is*.
    let appIcon: String?

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        platform = required.value("platform")
        minimumDeploymentTarget = required.value("minimumDeploymentTarget")
        let devices = required.value("targetDevices")
        try required.check()

        targetDevices = devices.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        appIcon = properties["appIcon"]
    }

    /// Pinned rather than derived from the type name: the derivation would make the
    /// domain `asset`, and every Apple platform node lives under `apple.`.
    static let settingNamespace = "apple.assetCatalogCompiler"
}

// MARK: - Node

public struct AssetCatalogCompiler: Node {
    public static let kind: UInt = 29

    // MARK: Ports

    static let configuration = "configuration"
    /// The catalog folders' manifests, one wire each; a formula wires them, so the port
    /// is static. Each is walked to every file through `subfolders` and `files`.
    static let catalogs = "catalogs"
    static let catalogSubfolders = "catalogSubfolders"
    static let catalogFiles = "catalogFiles"
    /// The tree actool wrote: `Assets.car` and the icon PNGs.
    static let output = "files"
    static let partialInfoPlist = "partialInfoPlist"
    static let infoLog = "infoLog"
    static let errorLog = "errorLog"

    static let outputFolder = "out"
    static let partialInfoPlistFile = "partial.plist"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(configuration), .optional(catalogs), .dynamic(catalogSubfolders), .dynamic(catalogFiles)],
        outputPorts: [output, partialInfoPlist, infoLog, errorLog]
    )

    // MARK: Processing

    /// The binary behind the tool version the configuration names: two builds of one
    /// version compile a catalog differently, and only a fingerprint of the binary tells
    /// them apart (B-17).
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try toolBinaryCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let configurationText = try input.inputValues[Self.configuration]!.values.first!.expectValue().resolveAsString()
        let configuration = try AssetCatalogCompilerConfiguration(properties: [String: String](plainText: configurationText))

        // The walk: every folder under a catalog is demanded as a manifest, every file as
        // a wire. Until all of both have arrived the result would be a catalog missing
        // files, which actool would happily compile into a wrong Assets.car.
        let catalogManifests   = FolderTreeWalk.manifests(in: input, port: Self.catalogs)
        let subfolderManifests = FolderTreeWalk.manifests(in: input, port: Self.catalogSubfolders)
        let allManifests       = (catalogManifests + subfolderManifests).map(\.manifest)
        let subfolderSpecs     = FolderTreeWalk.subfolderSpecs(of: allManifests)
        let fileSpecs          = FolderTreeWalk.fileSpecs(of: allManifests)
        let specs = [Self.catalogSubfolders: subfolderSpecs, Self.catalogFiles: fileSpecs]

        let arrivedSubfolders = Set(subfolderManifests.map(\.key))
        let arrivedFiles      = Set((input.inputValues[Self.catalogFiles] ?? [:]).keys)
        guard Set(subfolderSpecs.keys).isSubset(of: arrivedSubfolders),
              Set(fileSpecs.keys).isSubset(of: arrivedFiles) else {
            return Self.pending(inputWireSpecs: specs)
        }

        // A catalog goes into the sandbox under its own name — `Assets.xcassets/...` — with
        // every file below it at the same relative path.
        let catalogRoots = catalogManifests.map { Path($0.manifest.baseFolderPath) }
        func sandboxPath(forFile fullPath: String) -> String {
            let path = Path(fullPath)
            for root in catalogRoots {
                if let relative = path.relative(to: root), let name = root.lastComponent {
                    return (Path(name) / relative).string
                }
            }
            return path.lastComponent ?? fullPath
        }
        let inputFiles = try FolderTreeWalk.files(in: input, port: Self.catalogFiles, relativeTo: sandboxPath(forFile:))

        var arguments: [String] = catalogRoots.compactMap(\.lastComponent)
        arguments += ["--compile", Self.outputFolder]
        arguments += ["--platform", configuration.platform]
        arguments += ["--minimum-deployment-target", configuration.minimumDeploymentTarget]
        for device in configuration.targetDevices {
            arguments += ["--target-device", device]
        }
        if let appIcon = configuration.appIcon {
            arguments += ["--app-icon", appIcon]
        }
        arguments += ["--output-partial-info-plist", Self.partialInfoPlistFile]
        arguments += ["--output-format", "human-readable-text"]

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: configuration.toolDescriptor)
        let result = try tool.execute(arguments: arguments,
                                      environment: [:],
                                      inputFiles: inputFiles,
                                      expectedOutputFileNames: [Self.partialInfoPlistFile],
                                      expectedOutputFolders: [Self.outputFolder])

        let partialPlist: NodeValue
        if result.exitCode == 0, let plist = result.outputFiles[Self.partialInfoPlistFile] {
            partialPlist = .value(plist)
        } else {
            partialPlist = .noValue(reason: .error(messageDataObjectHash: try Self.failureMessage(for: result).intern()))
        }

        return .init(outputValues: [Self.output:           try result.asTreeNodeValue(folder: Self.outputFolder),
                                    Self.partialInfoPlist: partialPlist,
                                    Self.infoLog:          .value(try result.infoOutput.intern()),
                                    Self.errorLog:         .value(try result.errorOutput.intern())],
                     inputWireSpecs: specs)
    }

    /// What a failed run says: the tool's own failure message, naming actool, or, for a run
    /// that exits cleanly and writes no partial plist, that.
    static func failureMessage(for result: SimplifiedToolExecuteResult) -> String {
        result.exitCode == 0
            ? "actool exited with status 0 and wrote no '\(partialInfoPlistFile)'"
            : result.failureMessage(tool: "actool")
    }

    private static func pending(inputWireSpecs: [String: [String: GraphSpecNode]]) -> ProcessOutput {
        let pending = NodeValue.noValue(reason: .pending)
        return .init(outputValues: [output: pending, partialInfoPlist: pending, infoLog: pending, errorLog: pending],
                     inputWireSpecs: inputWireSpecs)
    }
}
