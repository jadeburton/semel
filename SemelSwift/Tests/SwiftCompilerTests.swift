//
//  SwiftCompilerTests.swift
//  semel_tests
//
//  A FolderManifest lists only a folder's immediate children, so discovering the sources
//  of a nested target takes more than one pass. These tests pin down that walk: which
//  subfolders the tool asks for, and which .swift files it ends up compiling.
//

@testable import SemelSwift
import XCTest
import SemelNodeKit
import SemelDatabaseModels

final class SwiftCompilerTests: SemelSwiftTestCase {

    private let descriptor = ToolDescriptor(name: "swiftc",
                                            version: "test-swiftc",
                                            platform: "macOS",
                                            architecture: "arm64",
                                            recursiveHash: nil)
    private var executor: RecordingToolRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        executor = RecordingToolRunner()
        ToolRunnerRegistry.instance.registerTool(descriptor: descriptor, toolExecutor: executor)
    }

    // MARK: - Helpers

    private func makeTool() throws -> SwiftCompiler {
        try SwiftCompiler(thisNode: NodeRecord(id: 1, kind: SwiftCompiler.kind))
    }

    private func file(_ name: String)   -> FolderManifestEntry { .init(name: name, isFolder: false, isPinned: true) }
    private func folder(_ name: String) -> FolderManifestEntry { .init(name: name, isFolder: true,  isPinned: true) }

    private func manifest(_ baseFolderPath: String, _ entries: [FolderManifestEntry]) throws -> NodeValue {
        .value(try FolderManifest(baseFolderPath: baseFolderPath, entries: entries).toJSON().intern())
    }

    private func makeInput(folder rootFolder: NodeValue,
                           subfolders: [String: NodeValue] = [:],
                           extraConfiguration: [String] = []) throws -> ProcessInput {
        let configuration = ([
            "toolDescriptor.name=\(descriptor.name)",
            "toolDescriptor.version=\(descriptor.version)",
            "toolDescriptor.platform=\(descriptor.platform)",
            "toolDescriptor.architecture=\(descriptor.architecture)",
            "moduleName=GRDB",
        ] + extraConfiguration).joined(separator: "\n")
        return ProcessInput(inputValues: [
            SwiftCompiler.configuration:   ["config": .value(try configuration.intern())],
            SwiftCompiler.inputFolder:     ["folder0": rootFolder],
            SwiftCompiler.inputSubfolders: subfolders,
        ])
    }

    private func sourceSpecs(_ output: ProcessOutput) throws -> [String] {
        try XCTUnwrap(output.inputWireSpecs[SwiftCompiler.inputSourceFiles]).keys.sorted()
    }

    private func subfolderSpecs(_ output: ProcessOutput) throws -> [String: String] {
        try XCTUnwrap(output.inputWireSpecs[SwiftCompiler.inputSubfolders]).rendered
    }

    // MARK: - Subfolder discovery

    func test_asksForAManifestForEachSubfolderOfTheSourceFolder() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [file("Fixits.swift"), folder("Core"), folder("Record")])))

        XCTAssertEqual(try subfolderSpecs(output),
                       ["input:/pkg/GRDB/Core":   "Folder(path: 'input:/pkg/GRDB/Core').manifest",
                        "input:/pkg/GRDB/Record": "Folder(path: 'input:/pkg/GRDB/Record').manifest"])
    }

    /// The walk goes one level per run, so a grandchild is only requested once its
    /// parent's manifest has arrived. Without this the tree stops at depth one.
    func test_asksForNestedSubfoldersOnceTheirParentManifestHasArrived() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [folder("Core")]),
            subfolders: ["input:/pkg/GRDB/Core": try manifest("input:/pkg/GRDB/Core", [folder("Support")])]))

        XCTAssertEqual(try subfolderSpecs(output)["input:/pkg/GRDB/Core/Support"],
                       "Folder(path: 'input:/pkg/GRDB/Core/Support').manifest")
    }

    /// An unpinned folder is a ghost — the user deleted it or never pushed it. Watching
    /// one would resurrect it, which is what ProjectFinder's isPinned check avoids too.
    func test_doesNotAskForManifestsForUnpinnedSubfolders() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [.init(name: "Core", isFolder: true, isPinned: false)])))

        XCTAssertEqual(try subfolderSpecs(output), [:])
    }

    // MARK: - Source discovery

    /// The bug this file was written for: GRDB has 1 of its 167 .swift files at the top
    /// level, so compiling only the immediate children handed swiftc `Fixits.swift` alone
    /// and it failed with "cannot find type 'Configuration' in scope".
    func test_compilesSwiftFilesFoundInsideSubfolders() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [file("Fixits.swift"), folder("Core")]),
            subfolders: ["input:/pkg/GRDB/Core": try manifest("input:/pkg/GRDB/Core",
                                                              [file("Configuration.swift"), file("Database.swift")])]))

        XCTAssertEqual(try sourceSpecs(output),
                       ["input:/pkg/GRDB/Core/Configuration.swift",
                        "input:/pkg/GRDB/Core/Database.swift",
                        "input:/pkg/GRDB/Fixits.swift"])
    }

    func test_ignoresNonSwiftFilesInsideSubfolders() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [folder("Core")]),
            subfolders: ["input:/pkg/GRDB/Core": try manifest("input:/pkg/GRDB/Core",
                                                              [file("Configuration.swift"), file("PrivacyInfo.xcprivacy")])]))

        XCTAssertEqual(try sourceSpecs(output), ["input:/pkg/GRDB/Core/Configuration.swift"])
    }

    func test_ignoresUnpinnedSwiftFilesInsideSubfolders() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [folder("Core")]),
            subfolders: ["input:/pkg/GRDB/Core": try manifest("input:/pkg/GRDB/Core",
                                                              [.init(name: "Gone.swift", isFolder: false, isPinned: false)])]))

        XCTAssertEqual(try sourceSpecs(output), [])
    }

    // MARK: - Compiling once the walk has finished (B-112)

    /// A run that finds a subfolder or a file not yet wired is part-way through the walk:
    /// a compile now would be of a partial source set, published as a module its importers
    /// compile against and then compile again.
    func test_aRunThatFindsSomethingNewDoesNotCompile() throws {
        var input = try makeInput(folder: try manifest("input:/pkg/GRDB", [file("Fixits.swift"), folder("Core")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/pkg/GRDB/Fixits.swift": .value(try "// fixits".intern())]

        let output = try makeTool().process(input: ProcessInput(inputValues: input))

        XCTAssertTrue(executor.invocations.isEmpty, "swiftc ran on a partial source set")
        XCTAssertEqual(try subfolderSpecs(output).keys.sorted(), ["input:/pkg/GRDB/Core"])
        for port in [SwiftCompiler.outputObject, SwiftCompiler.outputModule, SwiftCompiler.outputInterface] {
            XCTAssertTrue(output.outputValues[port]?.isPending == true, port)
        }
    }

    /// The run that finds nothing new compiles everything the walk found.
    func test_theRunThatFindsNothingNewCompilesEverySource() throws {
        var input = try makeInput(
            folder: try manifest("input:/pkg/GRDB", [file("Fixits.swift"), folder("Core")]),
            subfolders: ["input:/pkg/GRDB/Core": try manifest("input:/pkg/GRDB/Core", [file("Database.swift")])]).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/pkg/GRDB/Fixits.swift":        .value(try "// fixits".intern()),
                                                 "input:/pkg/GRDB/Core/Database.swift": .value(try "// database".intern())]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        XCTAssertEqual(executor.lastArguments.filter { $0.hasSuffix(".swift") },
                       ["input:/pkg/GRDB/Core/Database.swift", "input:/pkg/GRDB/Fixits.swift"])
    }

    // MARK: - Explicit source lists

    /// SPM lets one target's directory contain another's, kept apart by `sources:`.
    /// This repository's own executable target is `semel`, whose directory also
    /// holds SemelCLI's sources and the XCTest target — walking it wholesale
    /// compiles a sibling target's files and the test suite into the binary.
    func test_restrictsSourceDiscoveryToAnExplicitSourcesList() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/semel", [file("main.swift"), folder("CommandInterpreter")]),
            subfolders: ["input:/pkg/semel/CommandInterpreter":
                            try manifest("input:/pkg/semel/CommandInterpreter", [file("Repl.swift")])],
            extraConfiguration: ["sourcePaths=main.swift"]))

        XCTAssertEqual(try sourceSpecs(output), ["input:/pkg/semel/main.swift"])
    }

    func test_doesNotDescendIntoSubfoldersOutsideAnExplicitSourcesList() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/semel", [file("main.swift"), folder("Tests")]),
            extraConfiguration: ["sourcePaths=main.swift"]))

        XCTAssertEqual(try subfolderSpecs(output), [:])
    }

    /// A listed source path may sit inside a subfolder, so the walk still has to descend
    /// through that subfolder's ancestors to reach it.
    func test_descendsIntoASubfolderThatLeadsToAListedSourcePath() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/target", [folder("Core"), folder("Ignored")]),
            extraConfiguration: ["sourcePaths=Core/Thing.swift"]))

        XCTAssertEqual(try subfolderSpecs(output).keys.sorted(), ["input:/pkg/target/Core"])
    }

    func test_skipsExcludedPaths() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/target", [file("Keep.swift"), file("Drop.swift"), folder("Vendor")]),
            extraConfiguration: ["excludedPaths=Drop.swift,Vendor"]))

        XCTAssertEqual(try sourceSpecs(output), ["input:/pkg/target/Keep.swift"])
        XCTAssertEqual(try subfolderSpecs(output), [:])
    }

    /// A flat target must keep behaving exactly as it did before the walk existed —
    /// this is the shape every existing test project has.
    func test_flatSourceFolderStillCompilesItsFilesAndAsksForNoSubfolders() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/Sources/MyLibraryTargetA", [file("Thing.swift")])))

        XCTAssertEqual(try sourceSpecs(output), ["input:/pkg/Sources/MyLibraryTargetA/Thing.swift"])
        XCTAssertEqual(try subfolderSpecs(output), [:])
    }

    // MARK: - Extra sources

    /// A file a target takes from another target's folder is named one by one on the
    /// compiler and compiled beside the folder's own, under `extra/`.
    func test_extraSourceFilesAreCompiledBesideTheFoldersOwn() throws {
        var input = try makeInput(folder: try manifest("input:/ext/Sources", [file("Main.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/ext/Sources/Main.swift": .value(try "// main".intern())]
        input[SwiftCompiler.inputExtraSourceFiles] = ["Entity.swift": .value(try "// entity".intern())]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        XCTAssertEqual(executor.lastArguments.filter { $0.hasSuffix(".swift") },
                       ["extra/Entity.swift", "input:/ext/Sources/Main.swift"])
    }

    /// A Swift object records its compilation directory, and a `.swiftmodule` serializes the
    /// search paths it was built with — the sandbox root, in both. The canonical name closes
    /// the first; not serializing the options closes the second. Every compile here gets its
    /// own explicit `-I` flags, so nothing downstream needs the serialized set.
    func test_recordsTheCanonicalSandboxNameAndSerializesNoDebuggingOptions() throws {
        var input = try makeInput(folder: try manifest("input:/ext/Sources", [file("Main.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/ext/Sources/Main.swift": .value(try "// main".intern())]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        let arguments = executor.lastArguments
        let directory = try XCTUnwrap(arguments.firstIndex(of: "-file-compilation-dir"), "\(arguments)")
        XCTAssertEqual(arguments[directory + 1], ToolSandbox.canonicalRootName)
        let frontend = try XCTUnwrap(arguments.firstIndex(of: "-no-serialize-debugging-options"), "\(arguments)")
        XCTAssertEqual(arguments[frontend - 1], "-Xfrontend", "the frontend flag has no driver spelling")
    }

    /// A target that borrows every source it has — an extension whose folder no target
    /// owns — wires no folder at all, and compiles the extras alone.
    func test_compilesWithExtraSourceFilesAndNoFolder() throws {
        let configuration = """
            toolDescriptor.name=\(descriptor.name)
            toolDescriptor.version=\(descriptor.version)
            toolDescriptor.platform=\(descriptor.platform)
            toolDescriptor.architecture=\(descriptor.architecture)
            moduleName=Notifications
            """
        let input = ProcessInput(inputValues: [
            SwiftCompiler.configuration: ["config": .value(try configuration.intern())],
            SwiftCompiler.inputExtraSourceFiles: ["NotificationService.swift": .value(try "// service".intern())],
        ])

        _ = try makeTool().process(input: input)

        XCTAssertEqual(executor.lastArguments.filter { $0.hasSuffix(".swift") }, ["extra/NotificationService.swift"])
    }

    // MARK: - Module trees

    /// A package's `modules_P()` carries every `.swiftmodule` behind a product as one
    /// tree. The trees are merged into one folder on the import path — a module two
    /// products share is one file — so a target that imports two products compiles with
    /// a single `-I`.
    func test_moduleTreesAreMergedIntoOneFolderOnTheImportPath() throws {
        let timeline = try TreeManifest(entries: [.init(path: "Timeline.swiftmodule", hash: try "t".intern(), mode: 0o644),
                                                  .init(path: "Models.swiftmodule", hash: try "m".intern(), mode: 0o644)]).toJSON().intern()
        let explore = try TreeManifest(entries: [.init(path: "Explore.swiftmodule", hash: try "e".intern(), mode: 0o644),
                                                 .init(path: "Models.swiftmodule", hash: try "m".intern(), mode: 0o644)]).toJSON().intern()
        var input = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "import Timeline".intern())]
        input[SwiftCompiler.inputModuleTrees] = ["Timeline": .value(timeline), "Explore": .value(explore)]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        let arguments = executor.lastArguments
        XCTAssertEqual(arguments.filter { $0 == "-I" }.count, 1, "one import path for the merged trees: \(arguments)")
        XCTAssertTrue(arguments.contains("modules"), "\(arguments)")
        XCTAssertEqual(executor.invocations.last?.inputFileNames.filter { $0.hasPrefix("modules/") }.sorted(),
                       ["modules/Explore.swiftmodule", "modules/Models.swiftmodule", "modules/Timeline.swiftmodule"])
    }

    /// A `.swiftmodule` records the Clang modules it was built against, so a product's
    /// module tree carries their header folders too, each under its own name; every
    /// folder in the tree holding a module map goes on the import path as well.
    func test_aModuleMapInsideAModuleTreeIsOnTheImportPath() throws {
        let tree = try TreeManifest(entries: [.init(path: "Markdown.swiftmodule", hash: try "m".intern(), mode: 0o644),
                                              .init(path: "CAtomic/module.modulemap", hash: try "map".intern(), mode: 0o644),
                                              .init(path: "CAtomic/CAtomic.h", hash: try "h".intern(), mode: 0o644)]).toJSON().intern()
        var input = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "import Markdown".intern())]
        input[SwiftCompiler.inputModuleTrees] = ["Markdown": .value(tree)]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        let arguments = executor.lastArguments
        let importPaths = arguments.indices.filter { arguments[$0] == "-I" }.map { arguments[$0 + 1] }
        XCTAssertEqual(importPaths, ["modules", "modules/CAtomic"])
    }

    // MARK: - Framework trees (B-77)

    /// A binary target's framework slice, as a package's `frameworks_P()` carries it, is
    /// merged into one folder on the framework search path, so `import Sparkle` finds
    /// `Sparkle.framework/Modules`; with none, no `-F`.
    func test_frameworkTreesAreMergedIntoOneFolderOnTheFrameworkSearchPath() throws {
        let sparkle = try TreeManifest(entries: [
            .init(path: "Sparkle.framework/Modules/module.modulemap", hash: try "map".intern(), mode: 0o644),
            .init(path: "Sparkle.framework/Headers/Sparkle.h", hash: try "h".intern(), mode: 0o644),
        ]).toJSON().intern()
        var input = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "import Sparkle".intern())]
        input[SwiftCompiler.inputFrameworkTrees] = ["Updater": .value(sparkle)]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        let arguments = executor.lastArguments
        let searchPaths = arguments.indices.filter { arguments[$0] == "-F" }.map { arguments[$0 + 1] }
        XCTAssertEqual(searchPaths, ["frameworks"])
        XCTAssertFalse(arguments.contains("frameworks/Sparkle.framework"), "the module map is the framework's own: \(arguments)")
        XCTAssertEqual(executor.invocations.last?.inputFileNames.filter { $0.hasPrefix("frameworks/") }.sorted(),
                       ["frameworks/Sparkle.framework/Headers/Sparkle.h", "frameworks/Sparkle.framework/Modules/module.modulemap"])

        input[SwiftCompiler.inputFrameworkTrees] = ["Updater": .value(try TreeManifest(entries: []).toJSON().intern())]
        _ = try makeTool().process(input: ProcessInput(inputValues: input))
        XCTAssertFalse(executor.lastArguments.contains("-F"), "\(executor.lastArguments)")
    }

    // MARK: - A bridging header (B-77)

    private func bridgingInput() throws -> ProcessInput {
        let headers = try TreeManifest(entries: [.init(path: "Mac/NSOpenPanel+Extras.h", hash: try "@interface".intern(), mode: 0o644),
                                                 .init(path: "Mac/Private/WKPreferencesPrivate.h", hash: try "private".intern(), mode: 0o644),
                                                 .init(path: "Mac/App-Bridging-Header.h", hash: try "#import".intern(), mode: 0o644)])
            .toJSON().intern()
        var input = try makeInput(folder: try manifest("input:/app/Mac", [file("App.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Mac/App.swift": .value(try "NSOpenPanel().acceptOPML()".intern())]
        input[SwiftCompiler.bridgingHeader] = ["Mac/App-Bridging-Header.h": .value(try "#import \"NSOpenPanel+Extras.h\"".intern())]
        input[SwiftCompiler.headerTrees] = ["App": .value(headers)]
        return ProcessInput(inputValues: input)
    }

    /// The bridging header is placed under `objc/` at its path in the project and handed
    /// to `-import-objc-header`, with the target's headers beside it and each of their
    /// folders a search path for the importer, as Xcode's header map makes them; the header
    /// itself, in the target's tree too, is one file.
    func test_aBridgingHeaderIsImportedWithTheTargetsHeadersOnTheImportersPath() throws {
        _ = try makeTool().process(input: try bridgingInput())

        let arguments = executor.lastArguments
        let header = try XCTUnwrap(arguments.firstIndex(of: "-import-objc-header"))
        XCTAssertEqual(arguments[header + 1], "objc/Mac/App-Bridging-Header.h")
        let importerPaths = arguments.indices.filter { arguments[$0] == "-Xcc" }.map { arguments[$0 + 1] }
        XCTAssertEqual(importerPaths, ["-Iobjc/Mac", "-Iobjc/Mac/Private"])
        XCTAssertEqual(executor.invocations.last?.inputFileNames.filter { $0.hasPrefix("objc/") }.sorted(),
                       ["objc/Mac/App-Bridging-Header.h", "objc/Mac/NSOpenPanel+Extras.h", "objc/Mac/Private/WKPreferencesPrivate.h"])
    }

    /// swiftc refuses a module interface for a module with a bridging header, an
    /// application's: none is asked for or expected, and the module still is.
    func test_aModuleWithABridgingHeaderHasNoInterface() throws {
        _ = try makeTool().process(input: try bridgingInput())

        XCTAssertFalse(executor.lastArguments.contains("-emit-module-interface"), "\(executor.lastArguments)")
        XCTAssertTrue(executor.lastArguments.contains("-emit-module"), "\(executor.lastArguments)")
        XCTAssertEqual(executor.invocations.last?.expectedOutputFileNames, ["GRDB.o", "GRDB.swiftmodule"])
    }

    func test_aTargetWithoutABridgingHeaderImportsNoObjectiveC() throws {
        var input = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "let x = 1".intern())]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        XCTAssertFalse(executor.lastArguments.contains("-import-objc-header"), "\(executor.lastArguments)")
        XCTAssertTrue(executor.lastArguments.contains("-emit-module-interface"), "\(executor.lastArguments)")
    }

    // MARK: - What a rejected argument says (B-98)

    // swiftc's complaint names the argument it rejected and never the setting that produced
    // it. The failed output carries swiftc's line and then the key and value behind it.

    private func failureMessage(_ output: ProcessOutput, port: String) throws -> String {
        guard case .noValue(.error(let hash)) = output.outputValues[port] else {
            XCTFail("expected an error on \(port), got \(String(describing: output.outputValues[port]))")
            return ""
        }
        return try hash.resolveAsString()
    }

    func test_aTripleSwiftcRejectsIsReportedWithTheSettingItCameFrom() throws {
        executor.exitCode = 1
        executor.errorOutput = "error: unknown target 'nonsense'"

        var input = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")]),
                                  extraConfiguration: ["target=nonsense"]).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "// app".intern())]

        let output = try makeTool().process(input: ProcessInput(inputValues: input))

        let message = try failureMessage(output, port: SwiftCompiler.outputObject)
        XCTAssertTrue(message.contains("error: unknown target 'nonsense'"), "got \(message)")
        XCTAssertTrue(message.contains("`swift.compiler.target` is `nonsense`"), "got \(message)")
        XCTAssertTrue(message.contains("swiftc -print-target-info"), "got \(message)")
    }

    /// The SDK reaches the command line as the path xcrun resolved the name to, so the
    /// sentence is the only place the name the config file states appears.
    ///
    /// The failure this stands in for is an SDK that resolves but cannot serve the target —
    /// a macOS SDK under an iOS triple, which is what a half-converted iOS package builds
    /// with. A *misspelled* SDK name never reaches the tool: `resolveSDKPath` returns nil
    /// and the node throws first. Captured from
    /// `swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -target arm64-apple-ios17.0`.
    func test_anSDKSwiftcCannotLoadIsReportedWithTheSettingThatNamesIt() throws {
        executor.exitCode = 1
        executor.errorOutput = """
            <unknown>:0: warning: using sysroot for 'MacOSX' but targeting 'iPhone'
            <unknown>:0: error: unable to load standard library for target 'arm64-apple-ios17.0'
            """

        var input = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "// app".intern())]

        let output = try makeTool().process(input: ProcessInput(inputValues: input))

        let message = try failureMessage(output, port: SwiftCompiler.outputObject)
        XCTAssertTrue(message.contains("`swift.compiler.sdk` is `macosx`"), "got \(message)")
        XCTAssertTrue(message.contains("xcrun --sdk macosx --show-sdk-path"), "got \(message)")
    }

    /// An error in the source is about the source: nothing is added.
    func test_anErrorInTheSourceNamesNoSetting() throws {
        executor.exitCode = 1
        executor.errorOutput = "input:/app/Sources/App.swift:1:1: error: cannot find 'foo' in scope"

        var input = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")]),
                                  extraConfiguration: ["target=arm64-apple-macos14.0"]).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "foo()".intern())]

        let output = try makeTool().process(input: ProcessInput(inputValues: input))

        XCTAssertEqual(try failureMessage(output, port: SwiftCompiler.outputObject), """
            swiftc exited with status 1:
            input:/app/Sources/App.swift:1:1: error: cannot find 'foo' in scope
            """)
    }
}

// MARK: - Optimisation level

/// The first setting a `semel.config` can give the compiler that the linker has no use for.
/// Until it existed, both tools accepted an identical set of keys, so the per-tool filtering
/// had nothing real to keep apart and only ever caught typos.
final class SwiftOptimisationLevelTests: SemelSwiftTestCase {

    /// Named for what the user wants rather than for the flag: `-O` and `-Osize` are not
    /// points on a scale, and spelling flags directly in a config would put `-Ounchecked` —
    /// which removes bounds and overflow checks — one typo away.
    func test_mapsEachLevelToItsFlag() throws {
        XCTAssertEqual(try swiftOptimisationFlag("none"),  "-Onone")
        XCTAssertEqual(try swiftOptimisationFlag("speed"), "-O")
        XCTAssertEqual(try swiftOptimisationFlag("size"),  "-Osize")
    }

    /// Nothing declared emits no flag at all, so every tree that predates this setting
    /// builds the same arguments it built before — and keeps its cached objects.
    func test_declaringNothingEmitsNoFlag() throws {
        XCTAssertNil(try swiftOptimisationFlag(nil))
    }

    /// Loud rather than accommodating, like the SDK check: a misspelt level that silently
    /// compiled unoptimised would be discovered by someone benchmarking, not by the build.
    func test_anUnknownLevelFailsAndNamesTheValidOnes() {
        XCTAssertThrowsError(try swiftOptimisationFlag("-Ofast")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("-Ofast"), "should name what was declared, got \(message)")
            XCTAssertTrue(message.contains("none, speed or size"), "got \(message)")
        }
    }

    // MARK: - Which SDK and target

    private func configuration(_ extra: [String: String]) throws -> SwiftCompilerConfiguration {
        var properties = [
            "toolDescriptor.name": "swiftc",
            "toolDescriptor.version": "test",
            "toolDescriptor.platform": "macOS",
            "toolDescriptor.architecture": "arm64",
            "moduleName": "GRDB",
        ]
        properties.merge(extra) { _, new in new }
        return try SwiftCompilerConfiguration(properties: properties)
    }

    /// Nothing declared is the machine's macOS SDK and the host's default target — exactly
    /// what every existing tree built with, so their arguments and cache keys hold.
    func test_theSDKAndTargetDefaultToTheMachine() throws {
        let configuration = try self.configuration([:])

        XCTAssertEqual(configuration.sdk, "macosx")
        XCTAssertNil(configuration.target)
    }

    /// What a formula states about the target beyond its sources — conditions, an
    /// extension's flag — arrives comma-joined and is passed as given.
    func test_declaredArgumentsAreCarried() throws {
        let configuration = try self.configuration(["arguments": "-D,DEBUG,-application-extension"])
        XCTAssertEqual(configuration.arguments, ["-D", "DEBUG", "-application-extension"])
        XCTAssertEqual(try self.configuration([:]).arguments, [])
    }

    /// An iOS package names its SDK and target; both reach the command line.
    func test_aDeclaredSDKAndTargetAreCarried() throws {
        let configuration = try self.configuration(["sdk": "iphonesimulator",
                                                    "target": "arm64-apple-ios18.0-simulator"])

        XCTAssertEqual(configuration.sdk, "iphonesimulator")
        XCTAssertEqual(configuration.target, "arm64-apple-ios18.0-simulator")
    }
}
