// SwiftCompiler.swift
// semel
//

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

struct SwiftCompilerConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    /// Declared in semel.config; nil means whatever this machine has.
    let sdkVersion: String?
    /// Declared in semel.config; nil means no -O flag at all.
    /// Compiler-only: the linker takes no optimisation flag, so this key lives under
    /// `swift.compiler` and the linker's selector never sees it.
    let optimisationLevel: String?
    let moduleName: String
    let parseAsLibrary: Bool
    /// The target's `.swiftLanguageMode`, carried by the converter as a literal; nil means
    /// the compiler's default mode, which is what every target without one built with.
    let languageMode: String?
    /// SPM's `sources:` list, relative to the target folder. Empty means the whole tree.
    let sourcePaths: [String]
    /// SPM's `exclude:` list, relative to the target folder.
    let excludedPaths: [String]

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        moduleName = required.value("moduleName")
        try required.check()

        arguments = []
        environment = [:]
        sdkVersion = properties["sdkVersion"]
        optimisationLevel = properties["optimisationLevel"]
        parseAsLibrary = properties["parseAsLibrary"] != "false"
        languageMode = properties["languageMode"]
        sourcePaths = Self.pathList(properties["sourcePaths"])
        excludedPaths = Self.pathList(properties["excludedPaths"])
    }

    /// Configuration values are one line of `key=value`, so a list is comma-joined.
    private static func pathList(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// Where this node's settings live in a config file: `swift.compiler.sdkVersion`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "SwiftCompiler")
}

// MARK: - Source scope

/// Which files under a target's folder actually belong to the target.
///
/// SPM lets a target declare an explicit `sources:` list, and lets one target's directory
/// contain another's — this repository's own executable target is `semel`, whose
/// directory also holds SemelCLI's sources and the XCTest target. So "every .swift
/// file beneath the folder" is not the same thing as "this target's sources", and the
/// recursive walk needs both predicates to stay honest.
struct SourceScope {
    let roots: [String]
    let sourcePaths: [String]
    let excludedPaths: [String]

    /// A file belongs to the target when it sits under one of the listed source paths
    /// (or none were listed) and under none of the excluded ones.
    func includesFile(_ fullPath: String) -> Bool {
        guard let relative = relativePath(of: fullPath) else {
            return sourcePaths.isEmpty
        }

        guard !isExcluded(relative) else {
            return false
        }

        return sourcePaths.isEmpty || sourcePaths.contains { Self.isAtOrUnder(relative, $0) }
    }

    /// A folder is worth walking when it is under a listed source path *or* an ancestor
    /// of one — `sources: ["Core/Thing.swift"]` still has to descend through `Core`.
    func includesFolder(_ fullPath: String) -> Bool {
        guard let relative = relativePath(of: fullPath) else {
            return sourcePaths.isEmpty
        }

        guard !isExcluded(relative) else {
            return false
        }

        return sourcePaths.isEmpty || sourcePaths.contains {
            Self.isAtOrUnder(relative, $0) || Self.isAtOrUnder($0, relative)
        }
    }

    private func isExcluded(_ relative: String) -> Bool {
        excludedPaths.contains { Self.isAtOrUnder(relative, $0) }
    }

    /// Path beneath whichever target root contains `fullPath`, or nil if none does.
    private func relativePath(of fullPath: String) -> String? {
        for root in roots where fullPath.hasPrefix(root + "/") {
            return String(fullPath.dropFirst(root.count + 1))
        }
        return nil
    }

    /// True when `path` is `prefix` itself or sits inside it. Compared segment-wise so
    /// "CoreExtras" is not mistaken for something under "Core".
    private static func isAtOrUnder(_ path: String, _ prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }
}

// MARK: - Node

struct SwiftCompiler: Node {
    public static let kind: UInt = 20

    // MARK: Ports

    static let configuration         = "configuration"
    static let inputSourceFiles      = "sourceFiles"          // dynamic: one wire per .swift file
    static let inputFolder           = "inputFolder"          // manifest to watch for swift files
    /// Dynamic port — one manifest per subfolder discovered beneath `inputFolder`.
    /// A FolderManifest lists only its immediate children, so a nested source tree is
    /// walked one level per process() run: each pass wires the subfolders it has just
    /// learned about, which schedules another pass. Same idiom as ProjectFinder's
    /// watchedFolderManifest port. Wire key = the subfolder's full input path.
    static let inputSubfolders       = "inputSubfolders"
    static let inputModules          = "inputModules"         // one wire per upstream swiftmodule
    /// Folder manifests for system-library targets (e.g. GRDBSQLite).
    /// Each entry key becomes the subdirectory name placed in the sandbox.
    static let inputModuleMapFolders = "inputModuleMapFolders"
    /// Dynamic port — actual file content wired from StaticFile nodes discovered
    /// via inputModuleMapFolders.  Wire key format: "<dirName>/<filename>".
    static let inputModuleMapFiles   = "inputModuleMapFiles"
    static let outputObject          = "object"
    static let outputModule          = "swiftmodule"
    static let outputInterface       = "swiftinterface"
    static let infoLog               = "infoLog"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .required(configuration),
            .required(inputFolder),
            .optional(inputModules),
            .optional(inputModuleMapFolders),
            .dynamic(inputSourceFiles),
            .dynamic(inputSubfolders),
            .dynamic(inputModuleMapFiles),
        ],
        outputPorts: [outputObject, outputModule, outputInterface, infoLog]
    )

    // The SDK a build declares reaches this node the ordinary way: `swift.compiler.sdkVersion`
    // in a `semel.config` inside the input file system, wired in like anything else, so
    // changing it reschedules what depends on it. What is *linked against* still does not —
    // `-sdk` is resolved with `xcrun` at run time, and the SDK's own contents are never an
    // input at all. A declared version is checked against the machine rather than describing
    // it. See B-47.

    // MARK: - Inputs / Outputs

    struct SwiftCompilerInputs {
        let configuration: SwiftCompilerConfiguration
        let sourceFiles: [FileNameAndContent]
        let moduleFiles: [FileNameAndContent]
        let moduleMapFiles: [FileNameAndContent]
        let inputFolderManifests: [(String, FolderManifest)]
        let subfolderManifests: [(String, FolderManifest)]
        let moduleMapFolderManifests: [(String, FolderManifest)]

        init(input: ProcessInput) throws {
            let configString = try input.inputValues[SwiftCompiler.configuration]!
                .values.first!.expectValue().resolveAsString()

            configuration = try .init(properties: [String: String](plainText: configString))

            sourceFiles = try (input.inputValues[SwiftCompiler.inputSourceFiles] ?? [:])
                .map { fileName, nodeValue in
                    FileNameAndContent(filePath: fileName, hash: try nodeValue.expectValue())
                }
                .sorted { $0.filePath < $1.filePath }

            moduleFiles = try (input.inputValues[SwiftCompiler.inputModules] ?? [:])
                .map { fileName, nodeValue in
                    FileNameAndContent(filePath: fileName + ".swiftmodule", hash: try nodeValue.expectValue())
                }
                .sorted { $0.filePath < $1.filePath }

            // Module map files: wire key is already "<dirName>/<filename>".
            moduleMapFiles = try (input.inputValues[SwiftCompiler.inputModuleMapFiles] ?? [:])
                .map { wireKey, nodeValue in
                    FileNameAndContent(filePath: wireKey, hash: try nodeValue.expectValue())
                }
                .sorted { $0.filePath < $1.filePath }

            inputFolderManifests = try SwiftCompiler.decodeFolderManifests(
                input: input, port: SwiftCompiler.inputFolder)

            // Decoded strictly, like inputFolder: a subfolder manifest that failed to
            // arrive would silently shrink the source set, and a partial whole-module
            // compile fails with baffling "cannot find type" errors far from the cause.
            subfolderManifests = try SwiftCompiler.decodeFolderManifests(
                input: input, port: SwiftCompiler.inputSubfolders)

            var allModuleMapFolders = [(String, FolderManifest)]()
            for (key, value) in (input.inputValues[SwiftCompiler.inputModuleMapFolders] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let jsonStr = try? value.expectValue().resolveAsString(),
                      let manifest = try? TypeRegistry.decode(encodedJSON: jsonStr) as? FolderManifest
                else { continue }
                allModuleMapFolders.append((key, manifest))
            }
            moduleMapFolderManifests = allModuleMapFolders
        }
    }

    /// Decodes every FolderManifest wired to `port`, ordered by wire key.
    ///
    /// Sorted for the same reason the source file list is sorted: these end up as an
    /// ordered list feeding a command line, and Swift's Dictionary iteration order is
    /// seeded per process, so an unsorted walk would produce a different invocation
    /// on every run.
    private static func decodeFolderManifests(input: ProcessInput, port: String) throws -> [(String, FolderManifest)] {
        var result = [(String, FolderManifest)]()
        for (key, value) in (input.inputValues[port] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let object = try? TypeRegistry.decode(encodedJSON: value.expectValue().resolveAsString())
            guard let folderManifest = object as? FolderManifest else {
                throw NodeError.other(message: "Could not decode FolderManifest on port \(port) for '\(key)'")
            }
            result.append((key, folderManifest))
        }
        return result
    }

    struct SwiftCompilerOutputs {
        let outputObject:    NodeValue
        let outputModule:    NodeValue
        let outputInterface: NodeValue
        let infoLog:         NodeValue
        let inputSourceFilesSpecs:    [String: String]
        let inputSubfoldersSpecs:     [String: String]
        let inputModuleMapFilesSpecs: [String: String]

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftCompiler.outputObject:    outputObject,
                                 SwiftCompiler.outputModule:    outputModule,
                                 SwiftCompiler.outputInterface: outputInterface,
                                 SwiftCompiler.infoLog:         infoLog],
                  inputWireSpecs: [
                      SwiftCompiler.inputSourceFiles:    inputSourceFilesSpecs,
                      SwiftCompiler.inputSubfolders:     inputSubfoldersSpecs,
                      SwiftCompiler.inputModuleMapFiles: inputModuleMapFilesSpecs
                  ])
        }
    }

    // MARK: - Processing

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    private func buildInputSourceFilesSpecs(folderManifests: [(String, FolderManifest)],
                                                  scope: SourceScope) -> [String: String] {
        var result: [String: String] = [:]
        for folderManifest in folderManifests {
            for entry in folderManifest.1.entries where entry.isPinned && entry.name.hasSuffix(".swift") && !entry.isFolder {
                let fullPath = (Path(folderManifest.1.baseFolderPath) / entry.name).string
                guard scope.includesFile(fullPath) else { continue }
                result[fullPath] = "StaticFile(path: \"\(fullPath)\").output".replacingOccurrences(of: "\\'", with: "'")
            }
        }
        return result
    }

    /// Generates a Folder wire spec for every subfolder named in `folderManifests`.
    ///
    /// A FolderManifest is a non-recursive list of immediate children, so one pass only
    /// reaches one level down. Feeding this port's own manifests back in means each run
    /// discovers the next level and reschedules the node, until the tree is exhausted and
    /// the spec set stops changing — the same walk ProjectFinder does for its
    /// watched folders.
    ///
    /// Unpinned entries are ghosts (deleted, or never pushed); wiring one would resurrect
    /// a folder the user removed.
    private func buildInputSubfoldersSpecs(folderManifests: [(String, FolderManifest)],
                                                 scope: SourceScope) -> [String: String] {
        var result: [String: String] = [:]
        for (_, manifest) in folderManifests {
            for entry in manifest.entries where entry.isFolder && entry.isPinned {
                let fullPath = (Path(manifest.baseFolderPath) / entry.name).string
                guard scope.includesFolder(fullPath) else { continue }
                result[fullPath] = "Folder(path: '\(fullPath)').manifest"
            }
        }
        return result
    }

    /// Generates dynamic wire specs for all files inside each system-library
    /// folder manifest.  Wire key format: "<sandboxDirName>/<filename>".
    private func buildInputModuleMapFilesSpecs(moduleMapFolderManifests: [(String, FolderManifest)]) -> [String: String] {
        var result: [String: String] = [:]
        for (dirName, manifest) in moduleMapFolderManifests {
            for entry in manifest.entries where entry.isPinned && !entry.isFolder {
                let wireKey = Path(dirName) / entry.name
                result[wireKey.string] = "StaticFile(path: \"\(Path(manifest.baseFolderPath) / entry.name)\").output"
            }
        }
        return result
    }

    private func compile(inputs: SwiftCompilerInputs,
                         inputSourceFilesSpecs: [String: String],
                         inputSubfoldersSpecs: [String: String],
                         inputModuleMapFilesSpecs: [String: String]) throws -> SwiftCompilerOutputs {

        guard !inputs.sourceFiles.isEmpty else {
            let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try "SwiftCompiler: no source files".intern()))
            return .init(outputObject: error,
                         outputModule: error,
                         outputInterface: error,
                         infoLog: .value(""),
                         inputSourceFilesSpecs: inputSourceFilesSpecs,
                         inputSubfoldersSpecs: inputSubfoldersSpecs,
                         inputModuleMapFilesSpecs: inputModuleMapFilesSpecs)
        }

        let moduleName      = inputs.configuration.moduleName
        let objectOutput    = "\(moduleName).o"
        let moduleOutput    = "\(moduleName).swiftmodule"
        let interfaceOutput = "\(moduleName).swiftinterface"

        var arguments = [String]()

        try verifySDKVersion(inputs.configuration.sdkVersion)

        if let sdkPath = resolveSDKPath() {
            arguments.append("-sdk");                        arguments.append(sdkPath)
        }

        arguments.append("-module-name");                    arguments.append(moduleName)

        if let languageMode = try swiftLanguageModeVersion(inputs.configuration.languageMode) {
            arguments.append("-swift-version");              arguments.append(languageMode)
        }

        if inputs.configuration.parseAsLibrary {
            arguments.append("-parse-as-library")
        }

        arguments.append("-c")
        arguments.append("-whole-module-optimization")
        if let optimisation = try swiftOptimisationFlag(inputs.configuration.optimisationLevel) {
            arguments.append(optimisation)
        }
        arguments.append("-o");                              arguments.append(objectOutput)
        arguments.append("-emit-module")
        arguments.append("-emit-module-path");               arguments.append(moduleOutput)
        arguments.append("-emit-module-interface")
        arguments.append("-emit-module-interface-path");     arguments.append(interfaceOutput)

        if !inputs.moduleFiles.isEmpty {
            arguments.append("-I"); arguments.append(".")
        }

        // Add -I flags for each system-library module map directory.
        var moduleMapDirs = Set<String>()
        for file in inputs.moduleMapFiles {
            let dir = (file.filePath as NSString).deletingLastPathComponent
            if !dir.isEmpty { moduleMapDirs.insert(dir) }
        }
        for dir in moduleMapDirs.sorted() {
            arguments.append("-I"); arguments.append(dir)
        }

        for sourceFile in inputs.sourceFiles {
            arguments.append(sourceFile.filePath)
        }

        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor)

        let result = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputs.sourceFiles + inputs.moduleFiles + inputs.moduleMapFiles,
            expectedOutputFileNames: [objectOutput, moduleOutput, interfaceOutput])

        let objectBytes = result.outputFiles[objectOutput] ?? []
        let moduleBytes = result.outputFiles[moduleOutput] ?? []
        let interfaceBytes = result.outputFiles[interfaceOutput] ?? []

        guard result.exitCode == 0 else {
            let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try result.errorOutput.intern()))
            return .init(outputObject: error,
                         outputModule: error,
                         outputInterface: error,
                         infoLog: .value(try result.infoOutput.intern()),
                         inputSourceFilesSpecs: inputSourceFilesSpecs,
                         inputSubfoldersSpecs: inputSubfoldersSpecs,
                         inputModuleMapFilesSpecs: inputModuleMapFilesSpecs)
        }

        return .init(outputObject:    .value(try objectBytes.intern()),
                     outputModule:    .value(try moduleBytes.intern()),
                     outputInterface: .value(try interfaceBytes.intern()),
                     infoLog:         .value(try result.infoOutput.intern()),
                     inputSourceFilesSpecs: inputSourceFilesSpecs,
                     inputSubfoldersSpecs: inputSubfoldersSpecs,
                     inputModuleMapFilesSpecs: inputModuleMapFilesSpecs)
    }

    private func process(inputs: SwiftCompilerInputs) throws -> SwiftCompilerOutputs {
        // The target's own folder plus every subfolder discovered so far. Sources are
        // gathered from all of them, and each is re-scanned for further subfolders, so
        // the tree is walked one level per run until it is fully covered.
        let allSourceFolders = inputs.inputFolderManifests + inputs.subfolderManifests

        // Scoped to the target's own roots: a subfolder manifest's base sits deeper, so
        // relative paths must be measured from where the target actually starts.
        let scope = SourceScope(roots: inputs.inputFolderManifests.map { $0.1.baseFolderPath },
                                sourcePaths: inputs.configuration.sourcePaths,
                                excludedPaths: inputs.configuration.excludedPaths)

        let inputSourceFilesSpecs    = buildInputSourceFilesSpecs(folderManifests: allSourceFolders, scope: scope)
        let inputSubfoldersSpecs     = buildInputSubfoldersSpecs(folderManifests: allSourceFolders, scope: scope)
        let inputModuleMapFilesSpecs = buildInputModuleMapFilesSpecs(moduleMapFolderManifests: inputs.moduleMapFolderManifests)
        do {
            return try compile(inputs: inputs,
                               inputSourceFilesSpecs: inputSourceFilesSpecs,
                               inputSubfoldersSpecs: inputSubfoldersSpecs,
                               inputModuleMapFilesSpecs: inputModuleMapFilesSpecs)
        } catch {
            let errorNodeValue = NodeValue.noValue(reason: .error(messageDataObjectHash: try error.localizedDescription.intern()))
            return .init(outputObject: errorNodeValue,
                         outputModule: errorNodeValue,
                         outputInterface: errorNodeValue,
                         infoLog: .value(""),   // empty content never reaches the store
                         inputSourceFilesSpecs: inputSourceFilesSpecs,
                         inputSubfoldersSpecs: inputSubfoldersSpecs,
                         inputModuleMapFilesSpecs: inputModuleMapFilesSpecs)
        }
    }
}
