// SwiftLinker.swift
// semel
//
// Swift linker stage: links one or more .o object files into a final
// executable, dynamic library or static archive using `swiftc` as the driver.

import Foundation
import SemelNodeKit
import SemelDatabaseModels

// MARK: - Configuration

/// The artifact a link produces. A formula literal, like `outputName`: it says what the
/// product *is*, and no config file may change that.
enum SwiftLinkage: String, CaseIterable {
    case executable
    /// `lib<name>.dylib`, via `-emit-library`.
    case dynamicLibrary
    /// `lib<name>.a`, via `-emit-library -static`, which has swiftc drive libtool and
    /// write a plain `ar` archive — so the linker stays one tool.
    case staticArchive
}

struct SwiftLinkerConfiguration {
    let toolDescriptor: ToolDescriptor
    let arguments: [String]
    let environment: [String: String]
    /// Which SDK, as `xcrun --sdk` names it: `macosx` unless declared. See SwiftCompiler.
    let sdk: String
    /// The `-target` triple; nil passes none, which is the host.
    let target: String?
    /// Declared in semel.config; nil means whatever this machine has.
    let sdkVersion: String?
    let linkage: SwiftLinkage
    let outputName: String
    /// `frameworks`, `libraries` and `cxxRuntime`: what the project states its product
    /// needs from the linker, beside what a package product's `linkRequirements` wire says.
    let requirements: LinkRequirements
    /// Where the linked file finds the frameworks on `frameworkTrees` at run time —
    /// `@executable_path/../Frameworks` in a Mac app, `@executable_path/Frameworks` in an
    /// iOS one, `@loader_path` beside a package's own product — passed as an `-rpath` only
    /// when there is a framework to find. A literal of whoever lays the frameworks out.
    let frameworksRunpath: String?

    init(properties: [String: String]) throws {
        var required = RequiredSettings(properties: properties, namespace: Self.settingNamespace)
        toolDescriptor = .init(required: &required, properties: properties)
        outputName = required.value("outputName")
        let linkageName = required.value("linkage")
        try required.check()

        // Three forms and no default, so a bad spelling is an error, not an executable.
        guard let linkage = SwiftLinkage(rawValue: linkageName) else {
            let accepted = SwiftLinkage.allCases.map(\.rawValue).joined(separator: ", ")
            throw NodeError.other(message: "linkage '\(linkageName)' is not one of: \(accepted)")
        }
        self.linkage = linkage

        // Extra flags a formula states about the product — `-framework QuickLook`,
        // `-e _NSExtensionMain` — comma-joined like every list in a setting.
        arguments = (properties["arguments"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        requirements = LinkRequirements(properties: properties)
        frameworksRunpath = properties[Self.frameworksRunpathKey].flatMap { $0.isEmpty ? nil : $0 }

        // `-emit-library -static` drives `libtool` as a child process, which zeroes a
        // member's timestamp, uid and gid when it inherits ZERO_AR_DATE=1 — otherwise the
        // `ar` header carries the wall clock and two cold builds of the same inputs produce
        // different bytes. Only the static-archive linkage writes an archive.
        environment = linkage == .staticArchive ? ["ZERO_AR_DATE": "1"] : [:]
        sdk = properties["sdk"] ?? defaultSDKName
        target = properties["target"]
        sdkVersion = properties["sdkVersion"]
    }

    /// Where this node's settings live in a config file: `swift.linker.sdkVersion`.
    static let settingNamespace = derivedSettingNamespace(forTypeName: "SwiftLinker")

    static let frameworksRunpathKey = "frameworksRunpath"
}

// MARK: - Node

struct SwiftLinker: Node {
    public static let kind: UInt = 21

    /// 2: links with small objc_msgSend selector stubs (B-90), so a link of equal inputs
    /// differs from what version 1 wrote.
    /// 3: passes the frameworks, libraries and C++ runtime its settings and
    /// `linkRequirements` state (B-55).
    /// 4: tells clang the SDK with `-isysroot`, so the image records the SDK's version
    /// rather than its deployment target as the SDK it was built with (B-77).
    public static let implementationVersion = 4

    // MARK: Ports

    static let configuration = "configuration"
    static let input = "input"
    /// Dynamic port — one wire per static archive discovered through `libraryFolders`.
    static let libraries = "libraries"
    /// Folder manifests for the system-library targets this product reaches, directly or
    /// transitively.  A user drops a vendored `.a` beside the module map to have it linked
    /// in; with no archive present the modulemap's `link "sqlite3"` resolves against the
    /// SDK and the product depends on the system copy, which is the pre-existing default.
    static let libraryFolders = "libraryFolders"
    /// Trees of object files, one wire each — what a package's `objects_P()` carries: every
    /// object behind a product, decided by the package's converter, linked in by a formula
    /// that only knows the product's name. The trees are merged: two products that share
    /// a target share its object, and linking it twice would be a duplicate symbol.
    static let objectTrees = "objectTrees"
    /// Settings values, one wire each, saying what a package product's objects need from
    /// the linker — what a package's `linking_P()` carries (`LinkRequirements`): its
    /// targets' `linkedFramework`s and `linkedLibrary`s, and the C++ runtime when one was
    /// compiled from C++. A formula linking several products' objects wires each one's, and
    /// the link takes the union, as SwiftPM gives an executable every framework its
    /// dependencies name (B-55).
    static let linkRequirements = "linkRequirements"
    /// Trees of frameworks, one wire each — what a package's `frameworks_P()` carries: the
    /// slice of every binary target behind a product, under its own name (B-77). Merged
    /// into one `frameworks` folder on the framework search path, and each framework at
    /// its top linked by name.
    static let frameworkTrees = "frameworkTrees"
    /// The sandbox folder the framework trees are merged into.
    static let frameworksFolder = "frameworks"
    static let output = "output"
    static let infoLog = "infoLog"
    /// Declaring this port is what makes ProjectBuilder wire the linked file's Unix mode
    /// into its OutputFile wrapper, so `cp` can chmod it. Without it an executable is
    /// published at the default 0644 and will not run. Same arrangement as ClangLinker.
    static let fileMetadata = FileMetadata.portName

    public var thisNode: NodeRecord

    public init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    public static let descriptor = NodeDescriptor(
        inputPorts: [
            .required(configuration),
            .required(input),
            .optional(libraryFolders),
            .optional(objectTrees),
            .optional(linkRequirements),
            .optional(frameworkTrees),
            .dynamic(libraries),
        ],
        outputPorts: [output, infoLog, fileMetadata]
    )


    // MARK: Processing

    struct SwiftLinkerInputs {
        let configuration: SwiftLinkerConfiguration
        let objectFiles: [FileNameAndContent]
        let libraryFiles: [FileNameAndContent]
        let libraryFolderManifests: [(String, FolderManifest)]
        /// The configuration's requirements with every `linkRequirements` wire's.
        let requirements: LinkRequirements
        /// Every file of every framework tree, merged under `frameworks`.
        let frameworkFiles: [FileNameAndContent]

        /// `Sparkle` for `frameworks/Sparkle.framework/…`: every framework at the top of the
        /// merged trees, sorted, each once.
        var frameworkNames: [String] {
            let prefix = SwiftLinker.frameworksFolder + "/"
            let names = frameworkFiles.compactMap { file -> String? in
                guard file.filePath.hasPrefix(prefix) else {
                    return nil
                }
                let top = file.filePath.dropFirst(prefix.count).split(separator: "/").first.map(String.init) ?? ""
                return top.hasSuffix(".framework") ? String(top.dropLast(".framework".count)) : nil
            }
            return Set(names).sorted()
        }

        init(input: ProcessInput) throws {
            let configurationString = try input.firstWire(onRequiredPort: SwiftLinker.configuration).value.expectValue().resolveAsString()
            configuration = try .init(properties: [String: String](plainText: configurationString))

            // Sorted: these go straight onto the command line, and Swift Dictionary
            // iteration order changes from one process to the next.
            var objectFiles: [FileNameAndContent] = []

            for (fileName, nodeValue) in try input.wires(on: SwiftLinker.input).sorted(by: { $0.key < $1.key }) {
                objectFiles.append(.init(filePath: fileName, hash: try nodeValue.expectValue()))
            }
            objectFiles += try TreeManifest.mergedInputFiles(in: input, port: SwiftLinker.objectTrees, under: "objects")

            self.objectFiles = objectFiles

            var libraryFiles: [FileNameAndContent] = []

            for (fileName, nodeValue) in try input.wires(on: SwiftLinker.libraries).sorted(by: { $0.key < $1.key }) {
                libraryFiles.append(.init(filePath: fileName, hash: try nodeValue.expectValue()))
            }

            self.libraryFiles = libraryFiles

            var libraryFolderManifests = [(String, FolderManifest)]()

            for (key, value) in (input.inputValues[SwiftLinker.libraryFolders] ?? [:]).sorted(by: { $0.key < $1.key }) {

                guard let jsonString = try? value.expectValue().resolveAsString(),
                      let manifest = try? TypeRegistry.decode(encodedJSON: jsonString) as? FolderManifest else {
                    continue
                }

                libraryFolderManifests.append((key, manifest))
            }

            self.libraryFolderManifests = libraryFolderManifests

            var requirements = configuration.requirements
            for (_, value) in (input.inputValues[SwiftLinker.linkRequirements] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let text = try value.expectValue().resolveAsString()
                requirements = requirements.union(LinkRequirements(properties: [String: String](plainText: text)))
            }
            self.requirements = requirements
            frameworkFiles = try TreeManifest.mergedInputFiles(in: input, port: SwiftLinker.frameworkTrees,
                                                               under: SwiftLinker.frameworksFolder)
        }
    }

    struct SwiftLinkerOutputs {
        let output: NodeValue
        let infoLog: NodeValue
        let fileMetadata: NodeValue
        let librariesSpecs: [String: GraphSpecNode]

        func asProcessOutput() -> ProcessOutput {
            .init(outputValues: [SwiftLinker.output: output,
                                 SwiftLinker.infoLog: infoLog,
                                 SwiftLinker.fileMetadata: fileMetadata],
                  inputWireSpecs: [SwiftLinker.libraries: librariesSpecs])
        }
    }

    public func process(input: ProcessInput) throws -> ProcessOutput {
        try process(inputs: try .init(input: input)).asProcessOutput()
    }

    /// One wire per static archive sitting in a system library's folder.
    ///
    /// Only `.a` files: the module map, the shim and any vendored header in that folder
    /// belong to the compile, and handing them to the linker would be an error rather
    /// than merely noise.  A folder with no archive yields nothing, which is the
    /// "link against the system library" default.
    private func buildLibrariesSpecs(libraryFolderManifests: [(String, FolderManifest)]) -> [String: GraphSpecNode] {
        var result: [String: GraphSpecNode] = [:]

        for (_, manifest) in libraryFolderManifests {
            for entry in manifest.entries where entry.isPinned && !entry.isFolder && entry.name.hasSuffix(".a") {
                let fullPath = (Path(manifest.baseFolderPath) / entry.name).string
                result[fullPath] = .staticFile(at: fullPath)
            }
        }

        return result
    }

    func process(inputs: SwiftLinkerInputs) throws -> SwiftLinkerOutputs {

        let librariesSpecs = buildLibrariesSpecs(libraryFolderManifests: inputs.libraryFolderManifests)

        let outputName = inputs.configuration.outputName

        var arguments = [String]()
        // The arguments built from settings, collected as they are appended so a swiftc
        // diagnostic about one of them can name the key behind it (B-98).
        var settings = [SettingArgument]()
        let namespace = SwiftLinkerConfiguration.settingNamespace

        switch inputs.configuration.linkage {
        case .executable:     break
        case .dynamicLibrary: arguments.append("-emit-library")
        // libtool writes the archive: no debug map, and no -Xlinker to pass one to.
        case .staticArchive:  arguments.append(contentsOf: ["-emit-library", "-static"])
        }

        if inputs.configuration.linkage != .staticArchive {
            // ld's debug map (N_OSO) names each object file. Prefixed with the working
            // directory it is the object's sandbox-relative path, not the sandbox's own name.
            arguments.append(contentsOf: ["-Xlinker", "-oso_prefix", "-Xlinker", "."])
            // ld's default "fast" objc_msgSend selector stubs load objc_msgSend through a
            // GOT entry of their own, beside the one ordinary calls use, and which of the
            // two the stubs reference differs between identical links (B-90). Small stubs
            // branch to objc_msgSend instead, leaving one GOT entry and nothing to choose.
            arguments.append(contentsOf: ["-Xlinker", "-objc_stubs_small"])
        }

        // Pass the SDK path so swiftc's linker driver can find libSystem and
        // other system libraries when invoked directly (outside of xcodebuild).
        let sdk = inputs.configuration.sdk
        try verifySDKVersion(inputs.configuration.sdkVersion, sdk: sdk)

        guard let sdkPath = resolveSDKPath(sdk: sdk) else {
            throw NodeError.other(message: "no SDK named \(sdk) could be found on this machine "
                                         + "(swift.linker.sdk names it as `xcrun --sdk` would)")
        }
        arguments.append("-sdk")
        arguments.append(sdkPath)
        settings.append(.swiftSDK(key: "\(namespace).sdk", value: sdk))
        // The swift driver links through clang with `--sysroot`, from which clang reads no
        // SDK version, so ld records the deployment target as the SDK an image was built
        // with (`LC_BUILD_VERSION`'s `sdk 17.0` for an app linked against the 26.5 SDK).
        // The system keys behaviour on that version — an iOS app stamped 17.0 runs in the
        // compatibility mode an old app gets, without the current SDK's look (B-77). With
        // `-isysroot` clang reads the SDK's `SDKSettings.json` and tells ld the version, as
        // it does for Xcode. An archive is not linked by ld.
        if inputs.configuration.linkage != .staticArchive {
            arguments.append(contentsOf: ["-Xclang-linker", "-isysroot", "-Xclang-linker", sdkPath])
        }

        if let target = inputs.configuration.target {
            arguments.append("-target")
            arguments.append(target)
            settings.append(.swiftTarget(key: "\(namespace).target", value: target))
        }

        for objectFile in inputs.objectFiles {
            arguments.append(objectFile.filePath)
        }

        for libraryFile in inputs.libraryFiles {
            arguments.append(libraryFile.filePath)
        }

        // An archive is not linked: libtool takes no framework, and SwiftPM leaves a static
        // product's requirements to whatever links it — which is what `linking_P()` is for.
        if inputs.configuration.linkage != .staticArchive {
            arguments.append(contentsOf: inputs.requirements.frameworkAndLibraryArguments)
            // swiftc links the Swift runtime and not the C++ one; SwiftPM adds it when a
            // product reaches a C++ source, once however many there are.
            if inputs.requirements.cxxRuntime {
                arguments.append("-lc++")
            }
            // A binary target's framework, linked by name from the merged trees and found
            // at run time where whoever lays the product out puts it (B-77).
            let frameworkNames = inputs.frameworkNames
            if !frameworkNames.isEmpty {
                arguments.append(contentsOf: ["-F", Self.frameworksFolder])
                arguments.append(contentsOf: frameworkNames.flatMap { ["-framework", $0] })
                if let runpath = inputs.configuration.frameworksRunpath {
                    arguments.append(contentsOf: ["-Xlinker", "-rpath", "-Xlinker", runpath])
                }
            }
        }

        arguments.append("-o"); arguments.append(outputName)
        arguments.append(contentsOf: inputs.configuration.arguments)

        let tool = try ToolRunnerRegistry.instance.tool(descriptor: inputs.configuration.toolDescriptor,
                                                        namespace:  SwiftLinkerConfiguration.settingNamespace)

        var inputFiles: [FileNameAndContent] = []
        inputFiles.append(contentsOf: inputs.objectFiles)
        inputFiles.append(contentsOf: inputs.libraryFiles)
        if inputs.configuration.linkage != .staticArchive {
            inputFiles.append(contentsOf: inputs.frameworkFiles)
        }

        let result = try tool.execute(
            arguments: arguments,
            environment: inputs.configuration.environment,
            inputFiles: inputFiles,
            expectedOutputFileNames: [outputName])

        // A library is loaded or linked, not run, so only an executable needs the x bits.
        let mode: UInt16 = inputs.configuration.linkage == .executable ? FileMetadata.executableMode : FileMetadata.defaultMode
        let metadataJSON = (try? FileMetadata(mode: mode).jsonString()) ?? "{}"

        return .init(output: try result.asOutputNodeValue(tool: "swiftc", settings: settings),
                     infoLog: .value(try result.infoOutput.intern()),
                     fileMetadata: .value(try metadataJSON.intern()),
                     librariesSpecs: librariesSpecs)
    }
}
