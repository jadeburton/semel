// ClangCompiler.swift
// semel
//
// Clang compiler stage: compiles a preprocessed .p file into a .o object file.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct ClangCompilerConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    /// `cStandard` and `cxxStandard`; the one the source file's language needs is required,
    /// which `ClangLanguageStandards.standard(forLanguage:namespace:)` decides once the
    /// file itself is known.
    let standards: ClangLanguageStandards
    /// `modules` and `objectiveCARC` (B-77).
    let features: ClangLanguageFeatures
    /// The SDK the modules a preprocessed source imports come from, `-isysroot`. A machine
    /// setting, written by `semel-clang` as `clang.compiler.sdkPath`: preprocessed text
    /// needs no header, but with `modules` it still names the modules to load, and they are
    /// found in the SDK. Required when a source loads modules, which the language decides.
    let sdkPath: String?
    let target: String  // e.g. "arm64-apple-macos14.0"

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        target = required.value("target")
        try required.check()

        arguments = clangArguments(properties)
        environment = [:]
        standards = .init(properties: properties)
        features  = try .init(properties: properties, namespace: Self.settingNamespace, readsModuleName: false)
        sdkPath   = properties["sdkPath"]
    }

    /// `sdkPath` for a source in `language`: required when it loads modules, which fail
    /// without the SDK as `module 'Foundation' not found`; absent otherwise, as ever.
    func sdkPath(forLanguage language: String) throws -> String? {
        guard features.loadsModules(forLanguage: language) else {
            return sdkPath
        }
        var required = RequiredSettings(properties: sdkPath.map { ["sdkPath": $0] } ?? [:],
                                        namespace: Self.settingNamespace)
        let path = required.value("sdkPath")
        try required.check()
        return path
    }

    /// Where this node's settings live in a config file: `clang.compiler.<key>`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "ClangCompiler")
}

// MARK: - Node

public struct ClangCompiler: Node {
    public static let kind: UInt = 19

    /// 2: assembly — a preprocessed `.S`, a `.s` — is assembled as such with no standard,
    /// where it was compiled as C (B-55).
    /// 3: `sdkPath`, `modules` and `objectiveCARC` reach the command line (B-77).
    /// 4: several wires on a one-wire port are an error naming them, where one was compiled
    /// (B-141).
    /// 5: a failure is published as an `ErrorDocument`, the typed value a client renders,
    /// where it was a sentence (B-145).
    /// 6: the fingerprint of the SDK tree at `sdkPath` is in the key (B-47).
    public static let implementationVersion = 6

    // MARK: Ports

    static let configuration = "configuration"
    static let input = "input"
    /// Trees of frameworks, merged under `frameworks`, which is the `-F`: what the
    /// preprocessed text names by `#pragma clang module import` — a framework module the
    /// target links, one of the project's own (B-77) — the compiler loads again, from the
    /// framework's module map and headers.
    static let frameworkTrees = "frameworkTrees"
    /// The module trees of the package products the target links (`ClangModuleTrees`).
    static let moduleTrees = "moduleTrees"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [.required(configuration), .required(input), .optional(frameworkTrees, .many), .optional(moduleTrees, .many)],
        outputPorts: [output, errorLog, infoLog]
    )

    // MARK: Processing

    struct ClangCompilerInputs {
        let configuration: ClangCompilerConfiguration
        let inputSourceFile: FileNameAndContent
        /// Every file of every framework tree, merged under `frameworks`.
        let frameworkFiles: [FileNameAndContent]
        let modules: ClangModuleTrees

        init(input: ProcessInput) throws {
            frameworkFiles = try TreeManifest.mergedInputFiles(in: input, port: ClangCompiler.frameworkTrees,
                                                               under: ClangPreprocessor.frameworksFolder)
            modules = try ClangModuleTrees(input: input, port: ClangCompiler.moduleTrees)
            let configurationString = try input.onlyWire(onRequiredPort: ClangCompiler.configuration).value.expectValue().resolveAsString()
            configuration = try .init(properties: [String: String](plainText: configurationString))

            let input = try input.onlyWire(onRequiredPort: ClangCompiler.input)
            inputSourceFile = .init(filePath: input.key, hash: try input.value.expectValue())
        }
    }

    struct ClangCompilerOutputs {
        let output: NodeValue
        let errorLog: NodeValue
        let infoLog: NodeValue

        func asProcessOutput() throws -> ProcessOutput {
            .init(outputValues: [ClangCompiler.output: output,
                                 ClangCompiler.errorLog: errorLog,
                                 ClangCompiler.infoLog: infoLog],
                  inputWireSpecs: [:])
        }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    /// A compile's failure belongs to the source it compiles, by the wire's key.
    public func errorSubject(input: ProcessInput?) -> ErrorDocument.Subject? {
        input?.inputValues[Self.input]?.keys.min().map { .source(path: ClangPreprocessor.sourcePath(ofPreprocessed: $0)) }
    }

    func process(inputs: ClangCompilerInputs) throws -> ClangCompilerOutputs {

        let outputFilename = inputs.inputSourceFile.filePath + ".o"

        let language = ClangPreprocessor.language(for: inputs.inputSourceFile.filePath)

        var arguments = [String]()
        // The arguments built from settings, collected as they are appended so a clang
        // diagnostic about one of them can name the key behind it (B-98).
        var settings = [SettingArgument]()

        arguments.append("-x");      arguments.append(language)
        arguments.append("-c")

        if let standard = try inputs.configuration.standards.standard(
            forLanguage: language,
            namespace: ClangCompilerConfiguration.settingNamespace) {
            arguments.append("-std=\(standard)")
        }

        // The object records its compilation directory in DWARF. The sandbox's real name
        // would make two builds of one file differ; the canonical name makes them agree.
        arguments.append("-fdebug-compilation-dir=\(ToolSandbox.canonicalRootName)")

        arguments.append(inputs.inputSourceFile.filePath)
        arguments.append("-o");      arguments.append(outputFilename)
        arguments.append("-target"); arguments.append(inputs.configuration.target)
        settings.append(.clangTarget(key: "\(ClangCompilerConfiguration.settingNamespace).target",
                                     value: inputs.configuration.target))

        if let sdkPath = try inputs.configuration.sdkPath(forLanguage: language) {
            arguments.append("-isysroot"); arguments.append(sdkPath)
            settings.append(.clangSysroot(key: "\(ClangCompilerConfiguration.settingNamespace).sdkPath", value: sdkPath))
        }
        arguments.append(contentsOf: inputs.configuration.features.arguments(forLanguage: language))
        arguments.append(contentsOf: inputs.modules.arguments)
        if !inputs.frameworkFiles.isEmpty {
            arguments.append("-F"); arguments.append(ClangPreprocessor.frameworksFolder)
        }

        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor,
                                                        namespace:  ClangCompilerConfiguration.settingNamespace)

        let result = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: [.init(filePath: inputs.inputSourceFile.filePath, hash: inputs.inputSourceFile.hash)]
                      + inputs.frameworkFiles + inputs.modules.files,
            expectedOutputFileNames: [outputFilename])

        let subject = ErrorDocument.Subject.source(path: ClangPreprocessor.sourcePath(ofPreprocessed: inputs.inputSourceFile.filePath))
        return .init(output: try result.asOutputNodeValue(tool: "clang", subject: subject,
                                                          settings: settings),
                     errorLog: .value(try result.errorOutput.intern()),
                     infoLog: .value(try result.infoOutput.intern()))
    }
}
