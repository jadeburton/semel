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
    public static let implementationVersion = 2

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
    /// tells them apart (B-17).
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try toolBinaryCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let configurationText = try input.onlyWire(onRequiredPort: Self.configuration).value.expectValue().resolveAsString()
        let configuration = try IBToolCompilerConfiguration(properties: [String: String](plainText: configurationText))

        let documentWire = try input.onlyWire(onRequiredPort: Self.document)
        let documentPath = documentWire.key
        guard let compiledPath = Self.compiledPath(of: documentPath) else {
            throw NodeError.other(message: "IBToolCompiler: \(documentPath) is not an Interface Builder document; "
                                         + "it compiles \(Self.compiledExtensions.keys.sorted().map { ".\($0)" }.joined(separator: " and "))")
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
        let result = try tool.execute(arguments: arguments,
                                      environment: [:],
                                      inputFiles: [documentFile],
                                      expectedOutputFileNames: [],
                                      expectedOutputFolders: [Self.outputFolder])

        // A clean exit that wrote nothing would place nothing in the bundle, and the app
        // would fail far from here, loading a nib that is not there.
        let tree: NodeValue
        if result.exitCode == 0, (result.outputTrees[Self.outputFolder] ?? []).isEmpty {
            let message = "ibtool exited with status 0 and wrote nothing at \(compiledPath)"
            tree = .noValue(reason: .error(messageDataObjectHash: try message.intern()))
        } else {
            tree = try result.asTreeNodeValue(folder: Self.outputFolder, tool: "ibtool")
        }

        return .init(outputValues: [Self.output:   tree,
                                    Self.infoLog:  .value(try result.infoOutput.intern()),
                                    Self.errorLog: .value(try result.errorOutput.intern())],
                     inputWireSpecs: [:])
    }
}
