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

    /// The `-std` value for `language`, nil for assembly, which has no standard to state.
    ///
    /// Checked here rather than in `init(properties:)` because the language is not a
    /// setting: it comes from the source file arriving on a wire. A configuration stating
    /// only `cStandard` is complete for every C file and incomplete for the first C++ one,
    /// and the error names the key that file needs, under `namespace`.
    func standard(forLanguage language: String, namespace: String) throws -> String? {
        guard !ClangPreprocessor.assemblyLanguages.contains(language) else {
            return nil
        }
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

/// The `arguments` setting a clang node's configuration may carry: extra flags a project
/// states about its build — `-DLUA_USE_MACOSX`, `-Wno-parentheses-equality` — comma-joined
/// like every list in a setting, and appended after everything the node builds itself.
/// A define belongs to the preprocessor, which is the stage that sees the macros; the
/// compiler reads preprocessed text.
func clangArguments(_ properties: [String: String]) -> [String] {
    (properties["arguments"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
}

struct ClangPreprocessorConfiguration {
    let toolDescriptor: ToolDescriptor
    /// `defines`: macros as `NAME` or `NAME=value`, comma-joined, each passed as `-D`. What
    /// a Swift package's `cSettings: [.define(…)]` becomes (B-55): a key of its own, so the
    /// converter can state a target's defines without replacing the project's `arguments`.
    let defines: [String]
    let arguments: [String]
    let environment: [String: String]
    /// Path to the SDK root (e.g. `/path/to/MacOSX.sdk`).
    /// When set, `-isysroot <sdkPath>` is passed so clang can find system headers.
    /// A machine setting, written by `semel-clang` as `clang.preprocessor.sdkPath`.
    let sdkPath: String?
    /// `cStandard` and `cxxStandard`; the one the source file's language needs is required,
    /// which `ClangLanguageStandards.standard(forLanguage:namespace:)` decides once the
    /// file itself is known.
    let standards: ClangLanguageStandards
    /// `modules`, `objectiveCARC` and `moduleName` (B-77).
    let features: ClangLanguageFeatures
    let target: String  // e.g. "arm64-apple-macos14.0"

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        target = required.value("target")
        try required.check()

        defines   = (properties["defines"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        arguments = clangArguments(properties)
        environment = [:]
        sdkPath   = properties["sdkPath"]
        standards = .init(properties: properties)
        features  = try .init(properties: properties, namespace: Self.settingNamespace, readsModuleName: true)
    }

    /// Where this node's settings live in a config file: `clang.preprocessor.<key>`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "ClangPreprocessor")
}

// MARK: - Node

public struct ClangPreprocessor: Node {
    public static let kind: UInt = 17

    /// 2: a header nobody pushed is left to clang (B-79), where version 1 failed on it.
    /// 3: a header folder is walked to the bottom, where version 2 took its top level (B-55).
    /// 4: a `.S` is preprocessed as assembly with no standard, where it was taken for C.
    /// 5: `modules`, `objectiveCARC` and `moduleName` reach the command line (B-77).
    public static let implementationVersion = 5

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    // MARK: Ports

    static let configuration = "configuration"
    static let sourceFileInput = "input"
    static let includeFileLists = "includeFileLists"
    static let headerInputFiles = "headerInputFiles"
    /// Folder manifests, keyed by folder path. Given, every file under each folder, at any
    /// depth, is placed in the sandbox and the folder becomes an `-I`, and the include
    /// finder is not used: a C target inside a Swift package (swift-cmark) includes headers
    /// by search path — `#include <parser.h>` from another folder — which the finder,
    /// resolving quoted includes beside the including file only, cannot see. Hand-written
    /// formulas keep the finder; the converter generates this form (B-54).
    static let headerFolders = "headerFolders"
    /// Every subfolder below a header folder, keyed by full path: the walk that brings a
    /// nested header — `include/openssl/ssl.h`, a source's sibling in `src/lib/` — one
    /// level per pass, as `SwiftCompiler` walks its sources (B-55). Only the folders on
    /// `headerFolders` are `-I`s; a file below one is placed at its input-file-system path,
    /// which is its path relative to that folder's `-I` and to the file that includes it.
    static let headerSubfolders = "headerSubfolders"
    static let output = "output"
    static let errorLog = "errorLog"
    static let infoLog = "infoLog"

    /// A header nobody pushed is tolerated on `headerInputFiles` (see `absentHeaderPaths`),
    /// so a report does not name it: whether it is needed is clang's to say, and it says so
    /// in this node's own error when it is.
    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .required(configuration),
            .required(sourceFileInput),
            .dynamic(includeFileLists),
            .dynamic(headerInputFiles),
            // Optional rather than dynamic: a formula can wire only a static port, and
            // this one is wired by the generated formula, not by this node's own specs.
            .optional(headerFolders),
            .dynamic(headerSubfolders),
        ],
        outputPorts: [output, errorLog, infoLog],
        inputPortsToleratingAbsentValue: [headerInputFiles]
    )

    // MARK: Processing

    struct ClangPreprocessorInputs {
        let configuration: ClangPreprocessorConfiguration
        let inputSourceFile: FileNameAndContent
        let headerFiles: [FileNameAndContent]
        /// Headers the include finder named that nobody has pushed: the file does not exist.
        /// The finder reads quoted includes without evaluating a conditional, so SQLite's
        /// amalgamation names `windows.h`, `mingw.h` and a configure step's `sqlite_cfg.h`
        /// under `#if`s that are false on this machine (B-79). Such a header is left out of
        /// the sandbox and clang decides: an `#include` it reaches fails as "file not found",
        /// the node's own error, and one it skips costs nothing.
        let absentHeaderPaths: [String]
        let includePathLists: [String: [String]]

        /// Every header on a wire, present or absent: what the run waits on is each named
        /// header having arrived, and an absent one has arrived as far as it ever will.
        var wiredHeaderCount: Int { headerFiles.count + absentHeaderPaths.count }

        /// The same, by path.
        var wiredHeaderPaths: Set<String> { Set(headerFiles.map(\.filePath) + absentHeaderPaths) }

        /// The folders on `headerFolders`, ordered by wire key so the command line is
        /// the same for the same inputs.
        let headerFolderManifests: [(String, FolderManifest)]

        /// The subfolders below them that have arrived, keyed by full path.
        let headerSubfolderManifests: [String: FolderManifest]

        init(input: ProcessInput) throws {
            headerFolderManifests = FolderTreeWalk.manifests(in: input, port: ClangPreprocessor.headerFolders)
                .map { ($0.key, $0.manifest) }
            headerSubfolderManifests = Dictionary(
                FolderTreeWalk.manifests(in: input, port: ClangPreprocessor.headerSubfolders).map { ($0.key, $0.manifest) },
                uniquingKeysWith: { first, _ in first })

            let configurationString = try input.inputValues[ClangCompiler.configuration]!.values.first!.expectValue().resolveAsString()
            configuration = try .init(properties: [String: String](plainText: configurationString))

            let sourceFileInput = input.inputValues[ClangPreprocessor.sourceFileInput]!.first!
            inputSourceFile = .init(filePath: sourceFileInput.key, hash: try sourceFileInput.value.expectValue())

            let headerInputFiles = input.inputValues[ClangPreprocessor.headerInputFiles]!

            var headerFiles: [FileNameAndContent] = []
            var absentHeaderPaths: [String] = []

            for (headerFileName, nodeValue) in headerInputFiles {
                if case .noValue(reason: .initializing) = nodeValue {
                    absentHeaderPaths.append(headerFileName)
                    continue
                }
                headerFiles.append(.init(filePath: headerFileName, hash: try nodeValue.expectValue()))
            }

            self.headerFiles = headerFiles
            self.absentHeaderPaths = absentHeaderPaths

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

        let headerInputFilesWireSpecs: [String: GraphSpecNode]
        let includeFileListWireSpecs: [String: GraphSpecNode]
        var headerSubfolderWireSpecs: [String: GraphSpecNode] = [:]

        func asProcessOutput() -> ProcessOutput {
            return .init(outputValues: [ClangPreprocessor.output: output,
                                 ClangPreprocessor.errorLog: errorLog,
                                 ClangPreprocessor.infoLog: infoLog],
                  inputWireSpecs: [ClangPreprocessor.headerInputFiles: headerInputFilesWireSpecs,
                                          ClangPreprocessor.includeFileLists: includeFileListWireSpecs,
                                          ClangPreprocessor.headerSubfolders: headerSubfolderWireSpecs])
        }
    }

    /// The binary behind the tool version the configuration names: two builds of one
    /// version preprocess differently, and only a fingerprint of the binary tells them
    /// apart (B-17).
    public func cacheKeyMaterial(input: ProcessInput) throws -> String? {
        try toolBinaryCacheKeyMaterial(input: input, configurationPort: Self.configuration)
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    /// clang's `-x` for a `.S` file: assembly with `#include`s and macros. A preprocessed
    /// `.S.p` is compiled under the same name, as a preprocessed `.c.p` is compiled as C —
    /// running the preprocessor again over its output changes nothing.
    static let assemblyWithPreprocessor = "assembler-with-cpp"
    /// clang's `-x` for a `.s` file, which has no preprocessing phase: the compiler takes
    /// it as it is, and a formula does not preprocess it.
    static let assembly = "assembler"
    static let assemblyLanguages: Set<String> = [assemblyWithPreprocessor, assembly]

    /// Returns the clang `-x` language for `filePath`, handling raw source files (`.cpp`),
    /// preprocessed files (`.cpp.p`) and object files (`.cpp.p.o`): the source suffix is
    /// what is left once the stage suffixes are stripped.
    ///
    /// Case matters for three suffixes: `.C` is C++ by convention on case-sensitive systems,
    /// and `.c` is C; `.S` is assembly the preprocessor runs over, and `.s` assembly as it
    /// is (B-55). Every other suffix is matched case-insensitively (`.CPP` is still C++).
    static func language(for filePath: String) -> String {
        var name = filePath
        if name.hasSuffix(".o") { name.removeLast(2) }
        if name.hasSuffix(".p") { name.removeLast(2) }

        if name.hasSuffix(".C") {
            return "c++"
        }
        if name.hasSuffix(".S") {
            return assemblyWithPreprocessor
        }
        if name.hasSuffix(".s") {
            return assembly
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
                                 headerInputFilesWireSpecs: [String: GraphSpecNode],
                                 includeFileListWireSpecs: [String: GraphSpecNode],
                                 headerSubfolderWireSpecs: [String: GraphSpecNode] = [:]) throws -> ClangPreprocessorOutputs {

        let outputFilename = inputs.inputSourceFile.filePath + ".p"

        var arguments = [String]()
        // The arguments built from settings, collected as they are appended so a clang
        // diagnostic about one of them can name the key behind it (B-98).
        var settings = [SettingArgument]()
        let namespace = ClangPreprocessorConfiguration.settingNamespace

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

        if let standard = try inputs.configuration.standards.standard(
            forLanguage: language,
            namespace: ClangPreprocessorConfiguration.settingNamespace) {
            arguments.append("-std=\(standard)")
        }

        if let sdkPath = inputs.configuration.sdkPath {
            // -isysroot locates the SDK without stripping the compiler's own include
            // paths (-nostdinc would do that, breaking C++ standard-library headers
            // which live in the toolchain, not the SDK).
            arguments.append("-isysroot"); arguments.append(sdkPath)
            settings.append(.clangSysroot(key: "\(namespace).sdkPath", value: sdkPath))
        }

        arguments.append("-target"); arguments.append(inputs.configuration.target)
        settings.append(.clangTarget(key: "\(namespace).target", value: inputs.configuration.target))
        arguments.append(contentsOf: inputs.configuration.features.arguments(forLanguage: language))
        arguments.append(inputs.inputSourceFile.filePath)
        arguments.append("-o"); arguments.append(outputFilename)
        // Before `arguments`, so a project's own flags can still undefine or redefine one.
        arguments.append(contentsOf: inputs.configuration.defines.map { "-D\($0)" })
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor,
                                                        namespace:  ClangPreprocessorConfiguration.settingNamespace)

        var inputFiles: [FileNameAndContent] = [.init(filePath: inputs.inputSourceFile.filePath, hash: inputs.inputSourceFile.hash)]

        inputFiles.append(contentsOf: inputs.headerFiles)

        let result = try tool.execute(arguments: arguments,
                                      environment: inputs.configuration.environment,
                                      inputFiles: inputFiles,
                                      expectedOutputFileNames: [outputFilename])

        return .init(output: try result.asOutputNodeValue(tool: "clang", settings: settings),
                     errorLog: .value(try result.errorOutput.intern()),
                     infoLog: .value(try result.infoOutput.intern()),
                     headerInputFilesWireSpecs: headerInputFilesWireSpecs,
                     includeFileListWireSpecs: includeFileListWireSpecs,
                     headerSubfolderWireSpecs: headerSubfolderWireSpecs)
    }

    func process(inputs: ClangPreprocessorInputs) throws -> ClangPreprocessorOutputs {

        // Folders given: every file under them is a header input, no finder is consulted,
        // and the run waits until the walk is done and all of them are on the wire.
        if !inputs.headerFolderManifests.isEmpty {
            // Each folder from its own manifest down, through the subfolders that have
            // arrived; a hidden folder is not entered, as a formula's `**` does not enter one.
            // A folder that is itself on `headerFolders` — a target's `include`, below the
            // target's own folder — has arrived there and is not asked for twice.
            var arrived = inputs.headerSubfolderManifests
            for (_, manifest) in inputs.headerFolderManifests {
                arrived[manifest.baseFolderPath] = manifest
            }
            let rootPaths = Set(inputs.headerFolderManifests.map(\.1.baseFolderPath))
            var subfolderSpecs = [String: GraphSpecNode]()
            for rootPath in rootPaths.sorted() {
                let below = FolderTreeWalk.subfolderSpecs(below: rootPath, arrived: arrived) { subfolder in
                    Path(subfolder).lastComponent?.hasPrefix(".") == false
                }
                subfolderSpecs.merge(below.filter { !rootPaths.contains($0.key) }) { existing, _ in existing }
            }
            let reached = inputs.headerFolderManifests.map(\.1) + subfolderSpecs.keys.sorted().compactMap { arrived[$0] }
            // The source itself sits in its own folder and is already an input.
            let folderFileSpecs = FolderTreeWalk.fileSpecs(of: reached) { $0 != inputs.inputSourceFile.filePath }

            let walkFinished = subfolderSpecs.keys.allSatisfy { inputs.headerSubfolderManifests[$0] != nil }
            guard walkFinished, inputs.wiredHeaderPaths == Set(folderFileSpecs.keys) else {
                let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try "Still collecting header folders".intern()))
                return .init(output: error,
                             errorLog: error,
                             infoLog: error,
                             headerInputFilesWireSpecs: folderFileSpecs,
                             includeFileListWireSpecs: [:],
                             headerSubfolderWireSpecs: subfolderSpecs)
            }
            return try runPreprocessor(inputs: inputs,
                                       headerInputFilesWireSpecs: folderFileSpecs,
                                       includeFileListWireSpecs: [:],
                                       headerSubfolderWireSpecs: subfolderSpecs)
        }

        var headerInputFilesWireSpecs = [String: GraphSpecNode]()

        let setOfIncludeFiles: Set<String> = Set(inputs.includePathLists.flatMap { (_, list) in list })

        let aggregatedIncludePathList: [String] = .init(setOfIncludeFiles)

        for includePath in aggregatedIncludePathList {
            headerInputFilesWireSpecs[includePath] = .staticFile(at: includePath)
        }

        var includeFileListWireSpecs = [String: GraphSpecNode]()

        for sourcePath in (aggregatedIncludePathList + [inputs.inputSourceFile.filePath]) {
            includeFileListWireSpecs[sourcePath] = GraphSpecNode(
                ClangIncludeFinder.self,
                inputs: [ClangIncludeFinder.sourceFileInputPort: [sourcePath: .staticFile(at: sourcePath)]]
            ).port(ClangIncludeFinder.includePathListOutputPort)
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
        guard inputs.wiredHeaderCount == aggregatedIncludePathList.count else {
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
