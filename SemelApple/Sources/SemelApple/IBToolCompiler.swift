//
//  IBToolCompiler.swift
//  SemelApple
//
//  Runs `ibtool --compile` on one Interface Builder document: a `.xib` becomes the `.nib`
//  an app loads, and a `.storyboard` the `.storyboardc` folder of nibs it loads. What comes
//  out is a file for a xib on the Mac and a folder for a storyboard, and a xib for iOS can
//  come out as either, so the result is a tree, placed where the document sits in the
//  bundle: `Base.lproj/MainMenu.xib` compiles to `Base.lproj/MainMenu.nib`.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct IBToolCompilerConfiguration {
    let toolDescriptor: ToolDescriptor
    /// The platform's SDK on this machine, `--sdk`: a machine setting, written by
    /// `semel-swift prepare` as `apple.ibToolCompiler.sdkPath` (B-109).
    let sdkPath: String
    /// `15.0`: what decides which features a nib may use and so how it is encoded.
    let minimumDeploymentTarget: String
    /// `mac`, `iphone`, `ipad`; one `--target-device` each, as actool takes them.
    let targetDevices: [String]
    /// The module a class named in the document with `customModuleProvider="target"` is
    /// looked up in: the target's own. A formula literal, like the Swift compiler's
    /// `moduleName`, because it says what the product is.
    let module: String?

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        sdkPath = required.value("sdkPath")
        minimumDeploymentTarget = required.value("minimumDeploymentTarget")
        let devices = required.value("targetDevices")
        try required.check()

        targetDevices = devices.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        module = properties["module"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Pinned, like every Apple platform node's: under `apple.`.
    static let settingNamespace = "apple.ibToolCompiler"
}

// MARK: - Node

public struct IBToolCompiler: Node {
    public static let kind: UInt = 41
    /// 2: several wires on a one-wire port are an error naming them, where one was taken
    /// (B-141).
    /// 3: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    /// 4: the fingerprint of the SDK tree at `sdkPath` is in the key (B-47).
    /// 5: what ibtool wrote is published in canonical form, and a document compiled twice
    /// to two different canonical forms is an error, `toolOutputVaries` (B-154).
    /// 6: the operating system's build is in the key, since ibtool archives through the
    /// system's AppKit, and for an iOS SDK the simulator runtimes installed (B-153).
    public static let implementationVersion = 6

    // MARK: Ports

    static let configuration = "configuration"
    /// The document, one wire, keyed by where it sits in the bundle — `MainMenu.xib`,
    /// `Base.lproj/MainMenu.xib` — which is where the compiled document is placed in the
    /// tree. The key is not decoration: it is the path the tool is given and the path the
    /// output takes, and it is in the cache key as every wire key is.
    static let document = "document"
    /// The tree ibtool wrote: the `.nib` file or folder, or the `.storyboardc` folder.
    static let output = "files"
    static let infoLog = "infoLog"
    static let errorLog = "errorLog"

    static let outputFolder = "out"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(configuration), .required(document)],
        outputPorts: [output, infoLog, errorLog]
    )

    /// What each document compiles to, by extension.
    static let compiledExtensions = ["xib": "nib", "storyboard": "storyboardc"]

    /// `Base.lproj/MainMenu.xib` -> `Base.lproj/MainMenu.nib`; nil for a file that is not an
    /// Interface Builder document.
    static func compiledPath(of documentPath: String) -> String? {
        let path = documentPath as NSString
        guard let compiled = compiledExtensions[path.pathExtension.lowercased()] else {
            return nil
        }
        return path.deletingPathExtension + "." + compiled
    }

    // MARK: Processing

    /// The binary behind the tool version the configuration names: two builds of one
    /// version may compile a document differently, and only a fingerprint of the binary
    /// tells them apart (B-17). And the SDK tree behind `--sdk`, whose frameworks a
    /// document's classes are looked up in (B-47). Read from the raw text, as the binary's
    /// half is, because the key is computed before the configuration is checked. And the
    /// system's build, whose AppKit archives the nib, and for an iOS SDK the simulator
    /// runtimes, whose UIKit does (B-153).
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        guard case .value(let hash)? = try input.onlyWire(onOptionalPort: Self.configuration)?.value else {
            return nil
        }
        let properties = [String: String](plainText: try hash.resolveAsString())
        let lines = [sdkCacheKeyMaterial(sdkPathIn: properties),
                     toolBinaryCacheKeyMaterial(configuration: properties),
                     HostOperatingSystem.cacheKeyMaterial,
                     SimulatorRuntimes.cacheKeyMaterial(family: properties[sdkPathSettingKey].flatMap(SimulatorRuntimes.family(ofSDKPath:)))]
            .compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A compile's failure belongs to the document it compiles.
    public func errorSubject(input: ProcessInput?) -> ErrorDocument.Subject? {
        input?.inputValues[Self.document]?.keys.min().map { .resource(path: $0) }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let configurationText = try input.onlyWire(onRequiredPort: Self.configuration).value.expectValue().resolveAsString()
        let configuration = try IBToolCompilerConfiguration(properties: [String: String](plainText: configurationText))

        let documentWire = try input.onlyWire(onRequiredPort: Self.document)
        let documentPath = documentWire.key
        guard let compiledPath = Self.compiledPath(of: documentPath) else {
            throw ErrorCondition.notAnInterfaceBuilderDocument(path: documentPath,
                                                               compiles: Self.compiledExtensions.keys.sorted().map { ".\($0)" })
        }
        let documentFile = FileNameAndContent(filePath: documentPath, hash: try documentWire.value.expectValue())

        // What Xcode passes for a document it compiles, less what only its own build
        // needs: the partial Info.plist (no key of it is one an app launches without) and
        // the font activation that is an Interface Builder convenience.
        var arguments = ["--errors", "--warnings", "--notices"]
        if let module = configuration.module {
            arguments += ["--module", module]
        }
        for device in configuration.targetDevices {
            arguments += ["--target-device", device]
        }
        arguments += ["--minimum-deployment-target", configuration.minimumDeploymentTarget]
        arguments += ["--output-format", "human-readable-text"]
        arguments += ["--sdk", configuration.sdkPath]
        arguments += ["--compile", "\(Self.outputFolder)/\(compiledPath)", documentPath]

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: configuration.toolDescriptor,
                                                        namespace:  IBToolCompilerConfiguration.settingNamespace)
        func compile() throws -> SimplifiedToolExecuteResult {
            try tool.execute(arguments: arguments,
                             environment: InterfaceBuilderDaemon.environment,
                             inputFiles: [documentFile],
                             expectedOutputFileNames: [],
                             expectedOutputFolders: [Self.outputFolder])
        }
        let subject = ErrorDocument.Subject.resource(path: documentPath)
        let result = try compile()

        // A clean exit that wrote nothing would place nothing in the bundle, and the app
        // would fail far from here, loading a nib that is not there.
        var tree: NodeValue
        if result.exitCode == 0, (result.outputTrees[Self.outputFolder] ?? []).isEmpty {
            tree = try result.wroteNothingDocument(tool: "ibtool", paths: [compiledPath], subject: subject).published()
        } else {
            tree = try result.asTreeNodeValue(folder: Self.outputFolder, tool: "ibtool", subject: subject)
        }
        // ibtool is not a function of its input (B-154): what it wrote is published in
        // canonical form (`NibCanonicaliser`), and the document is compiled a second time,
        // whose canonical form must be the same. One that is not has a layout ibtool decides
        // afresh each run — frames its constraints do not give, or ambiguous constraints —
        // which is the document's to resolve.
        if case .value = tree {
            do {
                let first = try NibCanonicaliser.canonicalTree(result.outputTrees[Self.outputFolder] ?? [], document: documentPath)
                let again = try compile()
                let second = again.exitCode == 0
                    ? try NibCanonicaliser.canonicalTree(again.outputTrees[Self.outputFolder] ?? [], document: documentPath)
                    : []
                if let differing = Self.firstDifference(first, second) {
                    tree = try ErrorDocument.engine(.toolOutputVaries(tool: "ibtool", path: differing), subject: subject,
                                                    remedy: .resolveLayout(document: documentPath)).published()
                } else {
                    tree = .value(try TreeManifest(entries: first).toJSON().intern())
                }
            } catch let condition as ErrorCondition {
                tree = try ErrorDocument.engine(condition, subject: subject).published()
            }
        }

        return .init(outputValues: [Self.output:   tree,
                                    Self.infoLog:  .value(try result.infoOutput.intern()),
                                    Self.errorLog: .value(try result.errorOutput.intern())],
                     inputWireSpecs: [:])
    }

    /// The first path at which two trees differ, by path or by content; nil for one tree.
    static func firstDifference(_ first: [TreeManifestEntry], _ second: [TreeManifestEntry]) -> String? {
        let paths = Set(first.map(\.path)).union(second.map(\.path)).sorted()
        let firstByPath  = Dictionary(first.map { ($0.path, $0) }, uniquingKeysWith: { earlier, _ in earlier })
        let secondByPath = Dictionary(second.map { ($0.path, $0) }, uniquingKeysWith: { earlier, _ in earlier })
        return paths.first { firstByPath[$0] != secondByPath[$0] }
    }
}
