//
//  StringCatalogCompiler.swift
//  SemelApple
//
//  Runs `xcstringstool compile` on one string catalog. The languages are the catalog's,
//  so the result — one `<language>.lproj` folder per language, each holding the
//  `.strings` and `.stringsdict` tables — is a tree: one node for all of them, which is
//  what the tree is for.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct StringCatalogCompilerConfiguration {
    let toolDescriptor: ToolDescriptor

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        try required.check()
    }

    /// Pinned, like every Apple platform node's: under `apple.`.
    static let settingNamespace = "apple.stringCatalogCompiler"
}

// MARK: - Node

public struct StringCatalogCompiler: Node {
    public static let kind: UInt = 30
    /// 2: several wires on a one-wire port are an error naming them, where one was taken
    /// (B-141).
    /// 3: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    public static let implementationVersion = 3

    // MARK: Ports

    static let configuration = "configuration"
    /// The `.xcstrings` file, one wire. The wire's key names the file, as a wire key does
    /// everywhere — `'Localizable.xcstrings': StaticFile(...)` — and the table the tool
    /// writes is named after it, so the key is not decoration.
    static let catalog = "catalog"
    /// The tree xcstringstool wrote: `<language>.lproj/<table>.strings` and the like.
    static let output = "files"
    static let infoLog = "infoLog"
    static let errorLog = "errorLog"

    static let outputFolder = "out"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(configuration), .required(catalog)],
        outputPorts: [output, infoLog, errorLog]
    )

    // MARK: Processing

    /// The binary behind the tool version the configuration names: two builds of one
    /// version compile a catalog differently, and only a fingerprint of the binary tells
    /// them apart (B-17).
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try toolBinaryCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }

    /// A compile's failure belongs to the catalog it compiles.
    public func errorSubject(input: ProcessInput?) -> ErrorDocument.Subject? {
        input?.inputValues[Self.catalog]?.keys.min().map { .resource(path: $0) }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        let configurationText = try input.onlyWire(onRequiredPort: Self.configuration).value.expectValue().resolveAsString()
        let configuration = try StringCatalogCompilerConfiguration(properties: [String: String](plainText: configurationText))

        let catalogWire = try input.onlyWire(onRequiredPort: Self.catalog)
        // Under its own name: the table's name is the file's, and xcstringstool names
        // what it writes after it.
        let catalogName = Path(catalogWire.key).lastComponent ?? catalogWire.key
        let catalogFile = FileNameAndContent(filePath: catalogName, hash: try catalogWire.value.expectValue())

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: configuration.toolDescriptor,
                                                        namespace:  StringCatalogCompilerConfiguration.settingNamespace)
        let result = try tool.execute(arguments: ["compile", catalogName, "--output-directory", Self.outputFolder],
                                      environment: [:],
                                      inputFiles: [catalogFile],
                                      expectedOutputFileNames: [],
                                      expectedOutputFolders: [Self.outputFolder])

        return .init(outputValues: [Self.output:   try result.asTreeNodeValue(folder: Self.outputFolder, tool: "xcstringstool",
                                                                              subject: .resource(path: catalogWire.key)),
                                    Self.infoLog:  .value(try result.infoOutput.intern()),
                                    Self.errorLog: .value(try result.errorOutput.intern())],
                     inputWireSpecs: [:])
    }
}
