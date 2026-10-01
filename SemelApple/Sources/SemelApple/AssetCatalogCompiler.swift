//
//  AssetCatalogCompiler.swift
//  SemelApple
//
//  Runs `actool` over one or more asset catalogs — `.xcassets`, and the `.icon` folders
//  Icon Composer writes — for a platform. What comes out is decided by the catalogs: an
//  `Assets.car`, and one PNG per app-icon size the platform wants, so the result is a
//  tree, not a file. The partial Info.plist actool writes (the icon keys) is a value of
//  its own, for `InfoPlistBuilder` to merge.
//
//  actool is not a function of its inputs, so the `Assets.car` in the tree is not the file
//  it wrote but that file's canonical form, checked by `assetutil` to read as the same
//  catalog (`AssetCatalogCanonicaliser`, `AssetCatalogGuard`, B-89).

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
    /// The `assetutil` that checks the canonical `Assets.car` reads as the one actool wrote
    /// (B-89): a fact about the machine, written by `semel-swift prepare`.
    let assetutilPath: String

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        platform = required.value("platform")
        minimumDeploymentTarget = required.value("minimumDeploymentTarget")
        let devices = required.value("targetDevices")
        assetutilPath = required.value("assetutilPath")
        try required.check()

        targetDevices = devices.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        appIcon = properties["appIcon"]
    }

    /// Pinned rather than derived from the type name: the derivation would make the
    /// domain `asset`, and every Apple platform node lives under `apple.`.
    static let settingNamespace = "apple.assetCatalogCompiler"

    static let machineSettingKeys: Set<String> = ["assetutilPath"]
}

// MARK: - Node

public struct AssetCatalogCompiler: Node {
    public static let kind: UInt = 29
    /// 2: `Assets.car` is published in canonical form (B-89).
    /// 3: a catalog's tree is asked for, where its folders were walked (B-135).
    public static let implementationVersion = 3

    // MARK: Ports

    static let configuration = "configuration"
    /// The catalog folders' manifests, one wire each; a formula wires them, so the port
    /// is static. Each is read to every file through its tree and `files`.
    static let catalogs = "catalogs"
    /// Each catalog's subtree manifest, keyed by the catalog's path (B-135): its every
    /// folder, on the pass after the first however deep an image set sits.
    static let catalogTrees = "catalogTrees"
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
        inputPorts: [.required(configuration), .optional(catalogs), .dynamic(catalogTrees), .dynamic(catalogFiles)],
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
        let configurationText = try input.firstWire(onRequiredPort: Self.configuration).value.expectValue().resolveAsString()
        let configuration = try AssetCatalogCompilerConfiguration(properties: [String: String](plainText: configurationText))

        // Every folder under a catalog is read from the catalog's tree (B-135), every file
        // demanded as a wire. Until the trees and the files have all arrived the result
        // would be a catalog missing files, which actool would happily compile into a wrong
        // Assets.car.
        let catalogManifests = FolderTreeWalk.manifests(in: input, port: Self.catalogs)
        let trees            = FolderTreeWalk.trees(in: input, port: Self.catalogTrees)
        var treeSpecs: [String: GraphSpecNode] = [:]
        var allManifests: [String: FolderManifest] = [:]
        for catalog in catalogManifests.map(\.manifest) {
            treeSpecs[catalog.baseFolderPath] = .folderTree(at: catalog.baseFolderPath)
            guard let tree = trees[catalog.baseFolderPath] else {
                allManifests[catalog.baseFolderPath] = catalog
                continue
            }
            allManifests.merge(try tree.folderManifests(at: catalog.baseFolderPath)) { existing, _ in existing }
        }
        let fileSpecs = FolderTreeWalk.fileSpecs(of: allManifests.keys.sorted().compactMap { allManifests[$0] })
        let specs = [Self.catalogTrees: treeSpecs, Self.catalogFiles: fileSpecs]

        let arrivedFiles = Set((input.inputValues[Self.catalogFiles] ?? [:]).keys)
        guard Set(treeSpecs.keys).isSubset(of: Set(trees.keys)),
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

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: configuration.toolDescriptor,
                                                        namespace:  AssetCatalogCompilerConfiguration.settingNamespace)
        let result = try tool.execute(arguments: arguments,
                                      environment: [:],
                                      inputFiles: inputFiles,
                                      expectedOutputFileNames: [Self.partialInfoPlistFile],
                                      expectedOutputFolders: [Self.outputFolder])

        let tree: NodeValue
        var partialPlist: NodeValue
        if result.exitCode == 0, let plist = result.outputFiles[Self.partialInfoPlistFile] {
            partialPlist = .value(plist)
        } else {
            partialPlist = .noValue(reason: .error(messageDataObjectHash: try Self.failureMessage(for: result).intern()))
        }
        if result.exitCode == 0 {
            // A catalog that cannot be shown canonical is not published at all, so neither is
            // the plist that names its icon.
            do {
                let assetutil = try LocalFileSystemTool(localPath: configuration.assetutilPath)
                tree = .value(try Self.canonicalTree(of: result.outputTrees[Self.outputFolder] ?? [],
                                                     guardedBy: AssetCatalogGuard(assetutil: assetutil)))
            } catch let failure where failure is AssetCatalogCanonicaliserError || failure is AssetCatalogGuardError {
                tree = .noValue(reason: .error(messageDataObjectHash: try Self.notCanonicalMessage(failure).intern()))
                partialPlist = tree
            }
        } else {
            tree = try result.asTreeNodeValue(folder: Self.outputFolder)
        }

        return .init(outputValues: [Self.output:           tree,
                                    Self.partialInfoPlist: partialPlist,
                                    Self.infoLog:          .value(try result.infoOutput.intern()),
                                    Self.errorLog:         .value(try result.errorOutput.intern())],
                     inputWireSpecs: specs)
    }

    /// What actool wrote, with `Assets.car` in canonical form: nothing actool varies from
    /// compile to compile crosses the port (B-89). The canonical file must read, through
    /// `assetutil`, as the one actool wrote, or nothing is published.
    static func canonicalTree(of files: [TreeManifestEntry], guardedBy catalogGuard: AssetCatalogGuard) throws -> DataObjectHash {
        var entries: [TreeManifestEntry] = []
        for file in files {
            guard file.path == AssetCatalogGuard.catalogFile, case .file(let hash, let mode) = file.content else {
                entries.append(file)
                continue
            }
            let canonical     = try AssetCatalogCanonicaliser.canonicalise(try hash.resolve())
            let canonicalHash = try canonical.bytes.intern()
            try catalogGuard.check(originalHash: hash, canonicalHash: canonicalHash, canonical: canonical)
            entries.append(TreeManifestEntry(path: file.path, hash: canonicalHash, mode: mode))
        }
        return try TreeManifest(entries: entries).toJSON().intern()
    }

    static func notCanonicalMessage(_ failure: Error) -> String {
        "actool's Assets.car is not published: it could not be put in a canonical form that reads as the file actool wrote (B-89): \(failure)"
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
