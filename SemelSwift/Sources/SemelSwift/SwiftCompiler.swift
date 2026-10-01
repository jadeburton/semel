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
    /// Which SDK, as `xcrun --sdk` names it: `macosx` unless declared, `iphonesimulator`
    /// for an iOS package. The path handed to `-sdk`, the `sdkVersion` check and the SDK
    /// fingerprint in the cache key all follow it.
    let sdk: String
    /// The `-target` triple (`arm64-apple-ios18.0-simulator`); nil passes none, which is
    /// the host, as every tree built before this setting existed.
    let target: String?
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
    /// The target's `.enableUpcomingFeature` and `.enableExperimentalFeature` names, each an
    /// `-enable-upcoming-feature` or `-enable-experimental-feature` (B-77). Literals from the
    /// converter, as `languageMode` is.
    let upcomingFeatures: [String]
    let experimentalFeatures: [String]
    /// The target's Swift `.define` names, each a `-D`.
    let defines: [String]
    /// The package a package target belongs to, `-package-name`, which SwiftPM passes to
    /// every target so that `package` declarations are visible across the package's
    /// targets (SE-0386): CodeEditTextView's `package(set) public var textStorage` does
    /// not compile without one. A literal from the converter; nil for an app's target.
    let packageName: String?
    /// The target's `.unsafeFlags`, passed as they stand after everything else the
    /// settings give, as SwiftPM places them. A JSON list in the setting, since a flag may
    /// hold the comma every other list here is joined with.
    let unsafeFlags: [String]
    /// SPM's `sources:` list, relative to the target folder. Empty means the whole tree.
    let sourcePaths: [String]
    /// SPM's `exclude:` list, relative to the target folder.
    let excludedPaths: [String]
    /// The bundle the target's resources are built into, `FoodTruckKit_FoodTruckKit`, when
    /// it has any (B-77). Set, the compiler adds the source SwiftPM would generate: the
    /// `Bundle.module` accessor that finds that bundle at run time. A formula literal from
    /// the converter, so it is part of the node's identity and of its key.
    let resourceBundleName: String?

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        moduleName = required.value("moduleName")
        try required.check()

        // Extra flags a formula states about the target — `-D DEBUG`,
        // `-application-extension` — comma-joined like every list in a setting. A
        // formula literal, so a config file cannot change what the target is.
        arguments = Self.pathList(properties["arguments"])
        environment = [:]
        sdk = properties["sdk"] ?? defaultSDKName
        target = properties["target"]
        sdkVersion = properties["sdkVersion"]
        optimisationLevel = properties["optimisationLevel"]
        parseAsLibrary = properties["parseAsLibrary"] != "false"
        languageMode = properties["languageMode"]
        upcomingFeatures = Self.pathList(properties["upcomingFeatures"])
        experimentalFeatures = Self.pathList(properties["experimentalFeatures"])
        defines = Self.pathList(properties["defines"])
        packageName = properties["packageName"].flatMap { $0.isEmpty ? nil : $0 }
        unsafeFlags = try Self.flagList(properties["unsafeFlags"])
        sourcePaths = Self.pathList(properties["sourcePaths"])
        excludedPaths = Self.pathList(properties["excludedPaths"])
        resourceBundleName = properties["resourceBundleName"].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The source SwiftPM generates for a target with resources, as this build lays the
    /// bundle out: beside the executable in an iOS bundle, under `Contents/Resources` in
    /// a macOS one, or beside the code that asks, for a test or a tool run in place.
    /// Looked up at first use and kept, as SwiftPM's is.
    static func resourceBundleAccessorSource(bundleName: String) -> String {
        """
        import Foundation

        private final class SemelResourceBundleFinder {}

        extension Foundation.Bundle {
            /// The resource bundle of this module, `\(bundleName).bundle`.
            static let module: Bundle = {
                let bundleName = "\(bundleName).bundle"
                let candidates = [
                    Bundle.main.bundleURL,
                    Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"),
                    Bundle(for: SemelResourceBundleFinder.self).bundleURL,
                ]
                for candidate in candidates {
                    let path = candidate.appendingPathComponent(bundleName).path
                    if let bundle = Bundle(path: path) {
                        return bundle
                    }
                }
                fatalError("unable to find bundle named \\(bundleName)")
            }()
        }

        """
    }

    /// The name the accessor is placed under among the sources.
    static let resourceBundleAccessorFileName = "resource_bundle_accessor.swift"

    /// Configuration values are one line of `key=value`, so a list is comma-joined.
    private static func pathList(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// `unsafeFlags` as the converter writes it: a JSON list of strings, on one line.
    static func encodedFlagList(_ flags: [String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(flags), as: UTF8.self)
    }

    private static func flagList(_ value: String?) throws -> [String] {
        guard let value, !value.isEmpty else {
            return []
        }
        guard let flags = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) else {
            throw NodeError.other(message: "\(settingNamespace).unsafeFlags=\(value) is not a JSON list of strings")
        }
        return flags
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
    static let documentationCatalogExtension = "docc"

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
    /// Never a documentation catalog: SwiftPM and Xcode take a `.docc` folder as one
    /// item for `docc`, and the Swift a tutorial keeps in it — SwiftTreeSitter's
    /// `Documentation.docc/Code/…package.swift`, which imports `PackageDescription` — is
    /// not the target's.
    func includesFolder(_ fullPath: String) -> Bool {
        guard (fullPath as NSString).pathExtension.lowercased() != Self.documentationCatalogExtension else {
            return false
        }
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

    /// At 2, no module interface and no `swiftinterface` port: a package target's
    /// `-warnings-as-errors` made swiftc's warning that an interface wants library evolution
    /// fatal (B-77). At 3, the folder's tree is asked for on `inputFolderTrees`, where its
    /// subfolders were walked on `inputSubfolders` a level per run (B-135). At 4, a
    /// `.docc` folder is not walked for sources, and `packageName` is `-package-name`
    /// (B-77).
    public static let implementationVersion = 4

    // MARK: Ports

    static let configuration         = "configuration"
    static let inputSourceFiles      = "sourceFiles"          // dynamic: one wire per .swift file
    /// Source files a formula names one by one, beside the folder's — what a target takes
    /// from another target's folder. Placed in the sandbox under `extra/` by wire key.
    static let inputExtraSourceFiles = "extraSourceFiles"
    static let inputFolder           = "inputFolder"          // manifest to watch for swift files
    /// Dynamic port — the subtree manifest of each folder on `inputFolder`, keyed by that
    /// folder's path (B-135). A manifest lists only a folder's own children; the tree lists
    /// every folder below, so a nested source tree is known on the pass after the first,
    /// however deep, and its files are asked for then, where a walk asked for one more level
    /// of subfolders per run.
    static let inputFolderTrees      = "inputFolderTrees"
    static let inputModules          = "inputModules"         // one wire per upstream swiftmodule
    /// Trees of `.swiftmodule` files, one wire each — what a package's `modules_P()`
    /// carries: every module behind a product, decided by the package's converter, made
    /// importable by a formula that only knows the product's name. The trees are merged
    /// into one `modules` folder on the import path; two products sharing a target share
    /// its module.
    static let inputModuleTrees      = "moduleTrees"
    /// Trees of frameworks, one wire each — what a package's `frameworks_P()` carries: the
    /// slice of every binary target behind a product, each under its own name
    /// (`Sparkle.framework/…`), as `XCFrameworkSliceSelector` chose it (B-77). Merged into
    /// one `frameworks` folder and put on the framework search path, so `import Sparkle`
    /// finds `Sparkle.framework/Modules`.
    static let inputFrameworkTrees   = "frameworkTrees"
    /// Folder manifests for system-library targets (e.g. GRDBSQLite).
    /// Each entry key becomes the subdirectory name placed in the sandbox.
    static let inputModuleMapFolders = "inputModuleMapFolders"
    /// Dynamic port — actual file content wired from StaticFile nodes discovered
    /// via inputModuleMapFolders.  Wire key format: "<dirName>/<filename>".
    static let inputModuleMapFiles   = "inputModuleMapFiles"
    /// The sandbox folder the framework trees are merged into, and the `-F` it takes.
    static let frameworksFolder      = "frameworks"
    /// An application target's Objective-C bridging header (B-77): one wire, keyed by its
    /// path relative to the project — `Mac/NetNewsWire-Bridging-Header.h` — placed under
    /// `objc/` at that path and handed to `-import-objc-header`, so the target's Swift sees
    /// what it declares.
    static let bridgingHeader        = "bridgingHeader"
    /// Trees of the headers a bridging header may import, keyed by path relative to the
    /// project as the header is — the target's own headers, `headers_<Target>()` — merged
    /// under `objc/` beside it. Each folder holding one is a search path for the importer,
    /// which is what Xcode's header map gives a target: a quoted import finds a header of
    /// the target by name wherever in its folders the header sits.
    static let headerTrees           = "headerTrees"
    /// The folder the bridging header and the header trees are placed under.
    static let objectiveCFolder      = "objc"
    static let outputObject          = "object"
    static let outputModule          = "swiftmodule"
    static let infoLog               = "infoLog"

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .required(configuration),
            // Optional: a target that borrows every source it has, as an extension can,
            // has no folder of its own.
            .optional(inputFolder),
            .optional(inputExtraSourceFiles),
            .optional(inputModules),
            .optional(inputModuleTrees),
            .optional(inputFrameworkTrees),
            .optional(inputModuleMapFolders),
            .optional(bridgingHeader),
            .optional(headerTrees),
            .dynamic(inputSourceFiles),
            .dynamic(inputFolderTrees),
            .dynamic(inputModuleMapFiles),
        ],
        outputPorts: [outputObject, outputModule, infoLog]
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
        /// Every file of every module tree, placed under its wire's key.
        let moduleTreeFiles: [FileNameAndContent]
        /// Every file of every framework tree, merged under `frameworks`.
        let frameworkTreeFiles: [FileNameAndContent]
        let moduleMapFiles: [FileNameAndContent]
        /// The bridging header, under `objc/`, when one is wired.
        let bridgingHeader: FileNameAndContent?
        /// Every file of every header tree, under `objc/`, less the bridging header itself.
        let objectiveCHeaderFiles: [FileNameAndContent]
        let inputFolderManifests: [(String, FolderManifest)]
        /// The tree of each folder on `inputFolder` that has arrived, keyed by its path.
        let inputFolderTrees: [String: FolderSubtreeManifest]
        let moduleMapFolderManifests: [(String, FolderManifest)]
        /// The names of the wires placed on the dynamic ports so far.
        let wiredSourceFiles: Set<String>
        let wiredFolderTrees: Set<String>
        let wiredModuleMapFiles: Set<String>

        init(input: ProcessInput) throws {
            wiredSourceFiles    = Set((input.inputValues[SwiftCompiler.inputSourceFiles] ?? [:]).keys)
            wiredFolderTrees    = Set((input.inputValues[SwiftCompiler.inputFolderTrees] ?? [:]).keys)
            wiredModuleMapFiles = Set((input.inputValues[SwiftCompiler.inputModuleMapFiles] ?? [:]).keys)

            let configString = try input.firstWire(onRequiredPort: SwiftCompiler.configuration)
                .value.expectValue().resolveAsString()

            configuration = try .init(properties: [String: String](plainText: configString))

            let discovered = try (input.inputValues[SwiftCompiler.inputSourceFiles] ?? [:])
                .map { fileName, nodeValue in
                    FileNameAndContent(filePath: fileName, hash: try nodeValue.expectValue())
                }
            let extra = try (input.inputValues[SwiftCompiler.inputExtraSourceFiles] ?? [:])
                .map { fileName, nodeValue in
                    FileNameAndContent(filePath: "extra/" + fileName, hash: try nodeValue.expectValue())
                }
            // The accessor a target with resources compiles with (B-77): a source of this
            // node's making, interned like a file the walk found.
            var generated: [FileNameAndContent] = []
            if let bundleName = configuration.resourceBundleName {
                let source = SwiftCompilerConfiguration.resourceBundleAccessorSource(bundleName: bundleName)
                generated.append(FileNameAndContent(filePath: SwiftCompilerConfiguration.resourceBundleAccessorFileName,
                                                    hash: try source.intern()))
            }
            sourceFiles = (discovered + extra + generated).sorted { $0.filePath < $1.filePath }

            moduleFiles = try (input.inputValues[SwiftCompiler.inputModules] ?? [:])
                .map { fileName, nodeValue in
                    FileNameAndContent(filePath: fileName + ".swiftmodule", hash: try nodeValue.expectValue())
                }
                .sorted { $0.filePath < $1.filePath }

            moduleTreeFiles = try TreeManifest.mergedInputFiles(in: input, port: SwiftCompiler.inputModuleTrees, under: "modules")
            frameworkTreeFiles = try TreeManifest.mergedInputFiles(in: input, port: SwiftCompiler.inputFrameworkTrees,
                                                                   under: SwiftCompiler.frameworksFolder)

            let bridgingValues = input.inputValues[SwiftCompiler.bridgingHeader] ?? [:]
            let bridgingPaths  = bridgingValues.keys.sorted()
            guard bridgingPaths.count <= 1 else {
                throw NodeError.other(message: "SwiftCompiler: a target has one bridging header, and \(bridgingPaths.count) are wired: "
                                             + bridgingPaths.joined(separator: ", "))
            }
            var bridging: FileNameAndContent?
            if let path = bridgingPaths.first, let value = bridgingValues[path] {
                bridging = FileNameAndContent(filePath: (Path(SwiftCompiler.objectiveCFolder) / Path(path)).string, hash: try value.expectValue())
            }
            bridgingHeader = bridging
            objectiveCHeaderFiles = try TreeManifest.mergedInputFiles(in: input, port: SwiftCompiler.headerTrees,
                                                                      under: SwiftCompiler.objectiveCFolder)
                .filter { $0.filePath != bridging?.filePath }

            // Module map files: wire key is already "<dirName>/<filename>".
            moduleMapFiles = try (input.inputValues[SwiftCompiler.inputModuleMapFiles] ?? [:])
                .map { wireKey, nodeValue in
                    FileNameAndContent(filePath: wireKey, hash: try nodeValue.expectValue())
                }
                .sorted { $0.filePath < $1.filePath }

            inputFolderManifests = try SwiftCompiler.decodeFolderManifests(
                input: input, port: SwiftCompiler.inputFolder)

            // Decoded strictly, like inputFolder: a tree that failed to arrive would silently
            // shrink the source set, and a partial whole-module compile fails with baffling
            // "cannot find type" errors far from the cause.
            let trees = FolderTreeWalk.trees(in: input, port: SwiftCompiler.inputFolderTrees)
            for key in wiredFolderTrees.sorted() where trees[key] == nil {
                throw NodeError.other(message: "Could not decode FolderSubtreeManifest on port \(SwiftCompiler.inputFolderTrees) for '\(key)'")
            }
            inputFolderTrees = trees

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
        let outputObject: NodeValue
        let outputModule: NodeValue
        let infoLog:      NodeValue
        let inputSourceFilesSpecs:    [String: GraphSpecNode]
        let inputFolderTreesSpecs:    [String: GraphSpecNode]
        let inputModuleMapFilesSpecs: [String: GraphSpecNode]

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftCompiler.outputObject: outputObject,
                                 SwiftCompiler.outputModule: outputModule,
                                 SwiftCompiler.infoLog:      infoLog],
                  inputWireSpecs: [
                      SwiftCompiler.inputSourceFiles:    inputSourceFilesSpecs,
                      SwiftCompiler.inputFolderTrees:    inputFolderTreesSpecs,
                      SwiftCompiler.inputModuleMapFiles: inputModuleMapFilesSpecs
                  ])
        }
    }

    // MARK: - Processing

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    /// Generates dynamic wire specs for all files inside each system-library
    /// folder manifest.  Wire key format: "<sandboxDirName>/<filename>".
    private func buildInputModuleMapFilesSpecs(moduleMapFolderManifests: [(String, FolderManifest)]) -> [String: GraphSpecNode] {
        var result: [String: GraphSpecNode] = [:]
        for (dirName, manifest) in moduleMapFolderManifests {
            for entry in manifest.entries where entry.isPinned && !entry.isFolder {
                let wireKey = Path(dirName) / entry.name
                result[wireKey.string] = .staticFile(at: (Path(manifest.baseFolderPath) / entry.name).string)
            }
        }
        return result
    }

    private func compile(inputs: SwiftCompilerInputs,
                         inputSourceFilesSpecs: [String: GraphSpecNode],
                         inputFolderTreesSpecs: [String: GraphSpecNode],
                         inputModuleMapFilesSpecs: [String: GraphSpecNode]) throws -> SwiftCompilerOutputs {

        guard !inputs.sourceFiles.isEmpty else {
            let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try "SwiftCompiler: no source files".intern()))
            return .init(outputObject: error,
                         outputModule: error,
                         infoLog: .value(""),
                         inputSourceFilesSpecs: inputSourceFilesSpecs,
                         inputFolderTreesSpecs: inputFolderTreesSpecs,
                         inputModuleMapFilesSpecs: inputModuleMapFilesSpecs)
        }

        let moduleName      = inputs.configuration.moduleName
        let objectOutput    = "\(moduleName).o"
        let moduleOutput    = "\(moduleName).swiftmodule"

        var arguments = [String]()
        // The arguments built from settings, collected as they are appended so a swiftc
        // diagnostic about one of them can name the key behind it (B-98).
        var settings = [SettingArgument]()
        let namespace = SwiftCompilerConfiguration.settingNamespace

        let sdk = inputs.configuration.sdk
        try verifySDKVersion(inputs.configuration.sdkVersion, sdk: sdk)

        guard let sdkPath = resolveSDKPath(sdk: sdk) else {
            throw NodeError.other(message: "no SDK named \(sdk) could be found on this machine "
                                         + "(swift.compiler.sdk names it as `xcrun --sdk` would)")
        }
        arguments.append("-sdk");                            arguments.append(sdkPath)
        settings.append(.swiftSDK(key: "\(namespace).sdk", value: sdk))

        if let target = inputs.configuration.target {
            arguments.append("-target");                     arguments.append(target)
            settings.append(.swiftTarget(key: "\(namespace).target", value: target))
        }

        arguments.append("-module-name");                    arguments.append(moduleName)
        if let packageName = inputs.configuration.packageName {
            arguments.append("-package-name");               arguments.append(packageName)
        }

        if let languageMode = try swiftLanguageModeVersion(inputs.configuration.languageMode) {
            arguments.append("-swift-version");              arguments.append(languageMode)
        }
        for feature in inputs.configuration.upcomingFeatures {
            arguments.append("-enable-upcoming-feature");    arguments.append(feature)
        }
        for feature in inputs.configuration.experimentalFeatures {
            arguments.append("-enable-experimental-feature"); arguments.append(feature)
        }
        for define in inputs.configuration.defines {
            arguments.append("-D");                          arguments.append(define)
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
        // No module interface: SwiftPM writes one only with library evolution, which
        // nothing here builds, and swiftc warns that it wants that — an error under a
        // package's `-warnings-as-errors` (NetNewsWire's `RSWeb`, B-77). Every consumer
        // imports the binary `.swiftmodule`.

        // The object records its compilation directory; the canonical name keeps the
        // sandbox's real one out of it. The module would serialize the search paths it was
        // built with, sandbox root included; every consumer here is handed its own `-I`
        // flags, so the serialized copy is dropped. `-no-serialize-debugging-options` is a
        // frontend flag with no driver spelling.
        arguments.append("-file-compilation-dir");           arguments.append(ToolSandbox.canonicalRootName)
        arguments.append("-Xfrontend");                      arguments.append("-no-serialize-debugging-options")

        if !inputs.moduleFiles.isEmpty {
            arguments.append("-I"); arguments.append(".")
        }

        // The module trees are merged into one folder, and that folder is on the import
        // path — as is every folder in it holding a module map, since a tree carries the
        // C targets' headers a .swiftmodule was built against, each under its own name.
        if !inputs.moduleTreeFiles.isEmpty {
            arguments.append("-I"); arguments.append("modules")
            var moduleMapDirsInTrees = Set<String>()
            for file in inputs.moduleTreeFiles where (file.filePath as NSString).lastPathComponent == "module.modulemap" {
                moduleMapDirsInTrees.insert((file.filePath as NSString).deletingLastPathComponent)
            }
            for dir in moduleMapDirsInTrees.sorted() {
                arguments.append("-I"); arguments.append(dir)
            }
        }

        // A binary target's framework is found as the SDK's are, by name on a framework
        // search path; its module map is inside it (B-77).
        if !inputs.frameworkTreeFiles.isEmpty {
            arguments.append("-F"); arguments.append(Self.frameworksFolder)
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

        // The bridging header, and every folder holding a header beside it as a search
        // path for the importer's quoted imports. Relative, like every path here; the
        // module swiftc writes records the header it imported at its absolute path.
        // ISSUE: so an application's `.swiftmodule` names the sandbox. Nothing imports an
        // application's module and it is no product, so no build compares it, but it is
        // not the same bytes twice.
        if let bridgingHeader = inputs.bridgingHeader {
            let headerFolders = Set((inputs.objectiveCHeaderFiles + [bridgingHeader]).map {
                ($0.filePath as NSString).deletingLastPathComponent
            })
            for folder in headerFolders.sorted() {
                arguments.append("-Xcc"); arguments.append("-I\(folder)")
            }
            arguments.append("-import-objc-header"); arguments.append(bridgingHeader.filePath)
        }

        for sourceFile in inputs.sourceFiles {
            arguments.append(sourceFile.filePath)
        }

        arguments.append(contentsOf: inputs.configuration.unsafeFlags)
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor,
                                                        namespace:  SwiftCompilerConfiguration.settingNamespace)

        let result = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputs.sourceFiles + inputs.moduleFiles + inputs.moduleTreeFiles + inputs.frameworkTreeFiles
                      + inputs.moduleMapFiles + inputs.objectiveCHeaderFiles + (inputs.bridgingHeader.map { [$0] } ?? []),
            expectedOutputFileNames: [objectOutput, moduleOutput])

        // Stored by the runner; an output the tool did not write is the empty object.
        let objectHash = result.outputFiles[objectOutput] ?? ""
        let moduleHash = result.outputFiles[moduleOutput] ?? ""

        guard result.exitCode == 0 else {
            let message = result.failureMessage(tool: "swiftc", settings: settings)
            let error = NodeValue.noValue(reason: .error(messageDataObjectHash: try message.intern()))
            return .init(outputObject: error,
                         outputModule: error,
                         infoLog: .value(try result.infoOutput.intern()),
                         inputSourceFilesSpecs: inputSourceFilesSpecs,
                         inputFolderTreesSpecs: inputFolderTreesSpecs,
                         inputModuleMapFilesSpecs: inputModuleMapFilesSpecs)
        }

        return .init(outputObject: .value(objectHash),
                     outputModule: .value(moduleHash),
                     infoLog:      .value(try result.infoOutput.intern()),
                     inputSourceFilesSpecs: inputSourceFilesSpecs,
                     inputFolderTreesSpecs: inputFolderTreesSpecs,
                     inputModuleMapFilesSpecs: inputModuleMapFilesSpecs)
    }

    private func process(inputs: SwiftCompilerInputs) throws -> SwiftCompilerOutputs {
        // Scoped to the target's own roots: a subfolder manifest's base sits deeper, so
        // relative paths must be measured from where the target actually starts.
        let roots = inputs.inputFolderManifests.map(\.1)
        let scope = SourceScope(roots: roots.map(\.baseFolderPath),
                                sourcePaths: inputs.configuration.sourcePaths,
                                excludedPaths: inputs.configuration.excludedPaths)

        // Each folder's tree, asked for on the first run with the folder's own files; read
        // down into every folder the target's scope reaches once it has arrived (B-135). A
        // target's files are then known on the second run however deep they are, and a
        // flat target's on the first, as before.
        var inputFolderTreesSpecs: [String: GraphSpecNode] = [:]
        var allSourceFolders: [FolderManifest] = []
        for root in roots {
            inputFolderTreesSpecs[root.baseFolderPath] = .folderTree(at: root.baseFolderPath)
            guard let tree = inputs.inputFolderTrees[root.baseFolderPath] else {
                allSourceFolders.append(root)
                continue
            }
            let reached = try tree.folderManifests(at: root.baseFolderPath) { scope.includesFolder($0) }
            allSourceFolders += reached.keys.sorted().compactMap { reached[$0] }
        }

        // Only .swift files inside the target's scope are compiled.
        let inputSourceFilesSpecs = FolderTreeWalk.fileSpecs(of: allSourceFolders) {
            $0.hasSuffix(".swift") && scope.includesFile($0)
        }
        let inputModuleMapFilesSpecs = buildInputModuleMapFilesSpecs(moduleMapFolderManifests: inputs.moduleMapFolderManifests)

        // A run that has just found something is not finished: the new wires schedule
        // another run, and a compile now would be of a partial source set — a module its
        // importers compile against and then compile again (B-112). The compile waits for
        // the run that finds nothing new, which is one with every tree in.
        guard Set(inputSourceFilesSpecs.keys) == inputs.wiredSourceFiles,
              Set(inputFolderTreesSpecs.keys) == inputs.wiredFolderTrees,
              Set(inputModuleMapFilesSpecs.keys) == inputs.wiredModuleMapFiles else {
            let walking = NodeValue.noValue(reason: .pending)
            return .init(outputObject: walking,
                         outputModule: walking,
                         infoLog: .value(""),
                         inputSourceFilesSpecs: inputSourceFilesSpecs,
                         inputFolderTreesSpecs: inputFolderTreesSpecs,
                         inputModuleMapFilesSpecs: inputModuleMapFilesSpecs)
        }

        do {
            return try compile(inputs: inputs,
                               inputSourceFilesSpecs: inputSourceFilesSpecs,
                               inputFolderTreesSpecs: inputFolderTreesSpecs,
                               inputModuleMapFilesSpecs: inputModuleMapFilesSpecs)
        } catch {
            let errorNodeValue = NodeValue.noValue(reason: .error(messageDataObjectHash: try error.localizedDescription.intern()))
            return .init(outputObject: errorNodeValue,
                         outputModule: errorNodeValue,
                         infoLog: .value(""),   // empty content never reaches the store
                         inputSourceFilesSpecs: inputSourceFilesSpecs,
                         inputFolderTreesSpecs: inputFolderTreesSpecs,
                         inputModuleMapFilesSpecs: inputModuleMapFilesSpecs)
        }
    }
}
