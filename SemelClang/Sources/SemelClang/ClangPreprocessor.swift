// ClangPreprocessor.swift
// semel
//
// Clang preprocessor stage: runs `clang -E` on a .c file and its headers,
// producing a preprocessed .p file ready for the compiler stage.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - The language standard

/// The language standards a configuration states, one per language: `cStandard` for C and
/// Objective-C, `cxxStandard` for C++ and Objective-C++.
///
/// One key per language rather than one `std` for the package (B-48): a mixed project has
/// `.c` files that want `c17` and `.cpp` files that want `c++20`, and a single key could say
/// only one of them. Both are required, because neither language has a usable unstated
/// standard — which one clang assumes moves between releases for C (gnu99, gnu11, gnu17)
/// exactly as for C++. There is deliberately no fallback: a standard baked into Semel would
/// silently change what a previous build meant the moment Semel is upgraded.
struct ClangLanguageStandards {
    let c: String?
    let cxx: String?

    init(properties: [String: String]) {
        c   = properties["cStandard"]
        cxx = properties["cxxStandard"]
    }

    /// The `-std` value for `language`.
    ///
    /// Checked here rather than in `init(properties:)` because the language is not a
    /// setting: it comes from the source file arriving on a wire. A configuration stating
    /// only `cStandard` is complete for every C file and incomplete for the first C++ one,
    /// and the error names the key that file needs, under `namespace`.
    func standard(forLanguage language: String, namespace: String) throws -> String {
        let key   = language.hasSuffix("++") ? "cxxStandard" : "cStandard"
        let value = language.hasSuffix("++") ? cxx : c

        var required = RequiredSettings(properties: value.map { [key: $0] } ?? [:],
                                        namespace: namespace)
        let standard = required.value(key)
        try required.check()
        return standard
    }
}

// MARK: - Configuration

struct ClangPreprocessorConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    /// Path to the SDK root (e.g. `/path/to/MacOSX.sdk`).
    /// When set, `-isysroot <sdkPath>` is passed so clang can find system headers.
    /// Supply via `Configuration(sdkPath: '/path/to/MacOSX.sdk')` in the formula.
    let sdkPath: String?
    /// `cStandard` and `cxxStandard`; the one the source file's language needs is required,
    /// which `ClangLanguageStandards.standard(forLanguage:namespace:)` decides once the
    /// file itself is known.
    let standards: ClangLanguageStandards
    let target: String  // e.g. "arm64-apple-macos14.0"

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        target = required.value("target")
        try required.check()

        arguments = []
        environment = [:]
        sdkPath   = properties["sdkPath"]
        standards = .init(properties: properties)
    }

    /// Where this node's settings live in a config file: `clang.preprocessor.<key>`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "ClangPreprocessor")
}

// MARK: - Node

public struct ClangPreprocessor: Node {
    public static let kind: UInt = 17

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    // MARK: Ports

    static let configuration = "configuration"
    static let sourceFileInput = "input"
    static let includeFileLists = "includeFileLists"
    static let headerInputFiles = "headerInputFiles"
    /// Folder manifests, keyed by folder path. Given, every file in each folder is placed
    /// in the sandbox and the folder becomes an `-I`, and the include finder is not used:
    /// a C target inside a Swift package (swift-cmark) includes headers by search path —
    /// `#include <parser.h>` from another folder — which the finder, resolving quoted
    /// includes beside the including file only, cannot see. Hand-written formulas keep
    /// the finder; the converter generates this form (B-54).
    static let headerFolders = "headerFolders"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .required(configuration),
            .required(sourceFileInput),
            .dynamic(includeFileLists),
            .dynamic(headerInputFiles),
            // Optional rather than dynamic: a formula can wire only a static port, and
            // this one is wired by the generated formula, not by this node's own specs.
            .optional(headerFolders),
        ],
        outputPorts: [output, errorLog, infoLog]
    )

    // MARK: Processing

    struct ClangPreprocessorInputs {
        let configuration: ClangPreprocessorConfiguration
        let inputSourceFile: FileNameAndContent
        let headerFiles: [FileNameAndContent]
        let includePathLists: [String: [String]]
        /// The folders on `headerFolders`, ordered by wire key so the command line is
        /// the same for the same inputs.
        let headerFolderManifests: [(String, FolderManifest)]

        init(input: ProcessInput) throws {
            var folders: [(String, FolderManifest)] = []
            for (key, value) in (input.inputValues[ClangPreprocessor.headerFolders] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let json = try? value.expectValue().resolveAsString(),
                      let manifest = try? TypeRegistry.decode(encodedJSON: json) as? FolderManifest else {
                    continue
                }
                folders.append((key, manifest))
            }
            headerFolderManifests = folders

            let configurationString = try input.inputValues[ClangCompiler.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = try .init(properties: [String: String](plainText: configurationString))

            let sourceFileInput = input.inputValues[ClangPreprocessor.sourceFileInput]!.first!
            inputSourceFile = .init(filePath: sourceFileInput.key, hash: try sourceFileInput.value.expectValue())

            let headerInputFiles = input.inputValues[ClangPreprocessor.headerInputFiles]!

            var headerFiles: [FileNameAndContent] = []

            for (headerFileName, nodeValue) in headerInputFiles {
                headerFiles.append(.init(filePath: headerFileName, hash: try nodeValue.expectValue()))
            }

            self.headerFiles = headerFiles

            includePathLists = try Dictionary(uniqueKeysWithValues: input.inputValues[ClangPreprocessor.includeFileLists]!.map { includeFilesValue in
                let wireName = includeFilesValue.key
                let list = try includeFilesValue.value
                    .expectValue()
                    .resolveAsString()
                    .split(separator: "\n")
                    .map { String($0) }
                return (wireName, list)
            })
        }
    }

    struct ClangPreprocessorOutputs {
        let output: NodeValue
        let errorLog: NodeValue
        let infoLog: NodeValue

        let headerInputFilesWireSpecs: [String: String]
        let includeFileListWireSpecs: [String: String]

        func asProcessOutput() -> ProcessOutput {
            return .init(outputValues: [ClangPreprocessor.output: output,
                                 ClangPreprocessor.errorLog: errorLog,
                                 ClangPreprocessor.infoLog: infoLog],
                  inputWireSpecs: [ClangPreprocessor.headerInputFiles: headerInputFilesWireSpecs,
                                          ClangPreprocessor.includeFileLists: includeFileListWireSpecs])
        }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    /// Returns the clang `-x` language for `filePath`, handling raw source files (`.cpp`),
    /// preprocessed files (`.cpp.p`) and object files (`.cpp.p.o`): the source suffix is
    /// what is left once the stage suffixes are stripped.
    ///
    /// Case matters for one suffix: `.C` is C++ by convention on case-sensitive systems, and
    /// `.c` is C. Every other suffix is matched case-insensitively (`.CPP` is still C++).
    static func language(for filePath: String) -> String {
        var name = filePath
        if name.hasSuffix(".o") { name.removeLast(2) }
        if name.hasSuffix(".p") { name.removeLast(2) }

        if name.hasSuffix(".C") {
            return "c++"
        }
        let lower = name.lowercased()
        if lower.hasSuffix(".mm") {
            return "objective-c++"
        }
        if lower.hasSuffix(".m") {
            return "objective-c"
        }
        let cxxSuffixes = [".cpp", ".cc", ".cxx", ".c++"]
        return cxxSuffixes.contains(where: { lower.hasSuffix($0) }) ? "c++" : "c"
    }

    private func runPreprocessor(inputs: ClangPreprocessorInputs,
                                 headerInputFilesWireSpecs: [String: String],
                                 includeFileListWireSpecs: [String: String]) throws -> ClangPreprocessorOutputs {

        let outputFilename = inputs.inputSourceFile.filePath + ".p"

        var arguments = [String]()

        // Preprocess only.
        let language = Self.language(for: inputs.inputSourceFile.filePath)
        arguments.append("-E")
        arguments.append("-x"); arguments.append(language)
        arguments.append("-I"); arguments.append(".")
        // Each header folder is a search path: files are placed in the sandbox at their
        // input-file-system path, so the folder's path is its sandbox-relative directory.
        for (_, manifest) in inputs.headerFolderManifests {
            arguments.append("-I"); arguments.append(manifest.baseFolderPath)
        }

        let standard = try inputs.configuration.standards.standard(
            forLanguage: language,
            namespace: ClangPreprocessorConfiguration.settingNamespace)
        arguments.append("-std=\(standard)")

        if let sdkPath = inputs.configuration.sdkPath {
            // -isysroot locates the SDK without stripping the compiler's own include
            // paths (-nostdinc would do that, breaking C++ standard-library headers
            // which live in the toolchain, not the SDK).
            arguments.append("-isysroot"); arguments.append(sdkPath)
        }

        arguments.append("-target"); arguments.append(inputs.configuration.target)
        arguments.append(inputs.inputSourceFile.filePath)
        arguments.append("-o"); arguments.append(outputFilename)
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        var inputFiles: [FileNameAndContent] = [.init(filePath: inputs.inputSourceFile.filePath, hash: inputs.inputSourceFile.hash)]

        inputFiles.append(contentsOf: inputs.headerFiles)

        let result = try tool.execute(arguments: arguments,
                                      environment: inputs.configuration.environment,
                                      inputFiles: inputFiles,
                                      expectedOutputFileNames: [outputFilename])

        return .init(output: try result.asOutputNodeValue(),
                     errorLog: .value(try result.errorOutput.intern()),
                     infoLog: .value(try result.infoOutput.intern()),
                     headerInputFilesWireSpecs: headerInputFilesWireSpecs,
                     includeFileListWireSpecs: includeFileListWireSpecs)
    }

    func process(inputs: ClangPreprocessorInputs) throws -> ClangPreprocessorOutputs {

        // Folders given: every file in them is a header input, no finder is consulted, and
        // the run waits until all of them are on the wire.
        if !inputs.headerFolderManifests.isEmpty {
            var folderFileSpecs = [String: String]()
            for (_, manifest) in inputs.headerFolderManifests {
                for entry in manifest.entries where entry.isPinned && !entry.isFolder {
                    let path = (Path(manifest.baseFolderPath) / entry.name).string
                    // The source itself sits in its own folder and is already an input.
                    guard path != inputs.inputSourceFile.filePath else { continue }
                    folderFileSpecs[path] = "StaticFile(path: '\(path)').output"
                }
            }
            guard inputs.headerFiles.count == folderFileSpecs.count else {
                let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try "Still collecting header folders".intern()))
                return .init(output: error,
                             errorLog: error,
                             infoLog: error,
                             headerInputFilesWireSpecs: folderFileSpecs,
                             includeFileListWireSpecs: [:])
            }
            return try runPreprocessor(inputs: inputs,
                                       headerInputFilesWireSpecs: folderFileSpecs,
                                       includeFileListWireSpecs: [:])
        }

        var headerInputFilesWireSpecs = [String: String]()

        let setOfIncludeFiles: Set<String> = Set(inputs.includePathLists.flatMap { (_, list) in list })

        let aggregatedIncludePathList: [String] = .init(setOfIncludeFiles)

        for includePath in aggregatedIncludePathList {
            headerInputFilesWireSpecs[includePath] = "StaticFile(path: '\(includePath)').output"
        }

        var includeFileListWireSpecs = [String: String]()

        for sourcePath in (aggregatedIncludePathList + [inputs.inputSourceFile.filePath]) {
            includeFileListWireSpecs[sourcePath] = "ClangIncludeFinder(sourceFile: ['\(sourcePath)': StaticFile(path: '\(sourcePath)').output]).includePathList"
        }

        // There must be one ClangIncludeFinder attached to the .c file.

        if inputs.includePathLists[inputs.inputSourceFile.filePath] == nil {
            let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try "Still resolving include files".intern()))
            return .init(output: error,
                         errorLog: error,
                         infoLog: error,
                         headerInputFilesWireSpecs: headerInputFilesWireSpecs,
                         includeFileListWireSpecs: includeFileListWireSpecs)
        }

        // do we have input wires for each of the Headers mentioned in the aggregated Include list?
        //    no -> set our output to Error but set our Expected Header File Wires to equal the Include List, so that new wires will be connected
        //          that will cause us to be scheduled for processing a second time. and connecting a new wire instantly causes all downstream
        //          nodes' outputs to go to Pending, including us.
        //    yes -> proceed to running the preprocessor
        guard inputs.headerFiles.count == aggregatedIncludePathList.count else {
            let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try "Still resolving include files".intern()))
            return .init(output: error,
                         errorLog: error,
                         infoLog: error,
                         headerInputFilesWireSpecs: headerInputFilesWireSpecs,
                         includeFileListWireSpecs: includeFileListWireSpecs)
        }

        return try runPreprocessor(inputs: inputs,
                                   headerInputFilesWireSpecs: headerInputFilesWireSpecs,
                                   includeFileListWireSpecs: includeFileListWireSpecs)
    }
}
