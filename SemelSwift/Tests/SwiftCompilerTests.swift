//
//  SwiftCompilerTests.swift
//  semel_tests
//
//  A FolderManifest lists only a folder's immediate children, and the folder's tree every
//  name below it (B-135), so discovering the sources of a nested target takes the run that
//  asks for the tree and the one that has it. These tests pin down that read: what the tool
//  asks for, and which .swift files it ends up compiling.
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

    /// `subfolders` are the listings of the folders below the root, by path. With
    /// `treeArrived`, the root's tree is on `inputFolderTrees`, folded from them and the
    /// root's own listing (B-135); without, the run is the first, which has the root's
    /// manifest alone.
    private func makeInput(folder rootFolder: NodeValue,
                           subfolders: [String: NodeValue] = [:],
                           treeArrived: Bool = true,
                           extraConfiguration: [String] = []) throws -> ProcessInput {
        let configuration = ([
            "toolDescriptor.name=\(descriptor.name)",
            "toolDescriptor.version=\(descriptor.version)",
            "toolDescriptor.platform=\(descriptor.platform)",
            "toolDescriptor.architecture=\(descriptor.architecture)",
            "moduleName=GRDB",
        ] + extraConfiguration).joined(separator: "\n")
        var inputValues: [String: [String: NodeValue]] = [
            SwiftCompiler.configuration:  ["config": .value(try configuration.intern())],
            SwiftCompiler.inputFolder:    ["folder0": rootFolder],
            SwiftCompiler.bridgingHeader: [:],
        ]
        if treeArrived {
            var listings: [String: [FolderManifestEntry]] = [:]
            for value in [rootFolder] + Array(subfolders.values) {
                let listing: FolderManifest = try TypeRegistry.decodeAndCast(encodedJSON: try value.expectValue().resolveAsString())
                listings[listing.baseFolderPath] = listing.entries
            }
            let rootPath = try (TypeRegistry.decodeAndCast(encodedJSON: try rootFolder.expectValue().resolveAsString()) as FolderManifest)
                .baseFolderPath
            inputValues[SwiftCompiler.inputFolderTrees] =
                [rootPath: .value(try FolderSubtreeManifest.folding(at: rootPath, listings: listings).toJSON().intern())]
        }
        return ProcessInput(inputValues: inputValues)
    }

    private func sourceSpecs(_ output: ProcessOutput) throws -> [String] {
        try XCTUnwrap(output.inputWireSpecs[SwiftCompiler.inputSourceFiles]).keys.sorted()
    }

    private func treeSpecs(_ output: ProcessOutput) throws -> [String: String] {
        try XCTUnwrap(output.inputWireSpecs[SwiftCompiler.inputFolderTrees]).rendered
    }

    // MARK: - The folder's tree (B-135)

    /// The first run has the folder's own listing: it asks for the folder's tree, and for
    /// the files it can already see.
    func test_asksForTheTreeOfTheSourceFolderAndItsOwnFilesOnTheFirstRun() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [file("Fixits.swift"), folder("Core"), folder("Record")]),
            treeArrived: false))

        XCTAssertEqual(try treeSpecs(output), ["input:/pkg/GRDB": "Folder(path: 'input:/pkg/GRDB').subtreeManifest"])
        XCTAssertEqual(try sourceSpecs(output), ["input:/pkg/GRDB/Fixits.swift"])
    }

    /// Once the tree is in, every folder at every depth is read from it and its files
    /// asked for, in one run: a grandchild's file with the rest, and nothing more asked
    /// for than the tree.
    func test_asksForTheFilesOfEveryFolderInTheTreeOnceItHasArrived() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [folder("Core")]),
            subfolders: ["input:/pkg/GRDB/Core":         try manifest("input:/pkg/GRDB/Core", [folder("Support")]),
                         "input:/pkg/GRDB/Core/Support": try manifest("input:/pkg/GRDB/Core/Support", [file("Utils.swift")])]))

        XCTAssertEqual(try sourceSpecs(output), ["input:/pkg/GRDB/Core/Support/Utils.swift"])
        XCTAssertEqual(try treeSpecs(output).keys.sorted(), ["input:/pkg/GRDB"])
    }

    /// An unpinned folder is a ghost — the user deleted it or never pushed it. Its files are
    /// not asked for, which would resurrect them.
    func test_doesNotReadIntoUnpinnedSubfolders() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [.init(name: "Core", isFolder: true, isPinned: false)]),
            subfolders: ["input:/pkg/GRDB/Core": try manifest("input:/pkg/GRDB/Core", [file("Gone.swift")])]))

        XCTAssertEqual(try sourceSpecs(output), [])
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

    /// A run that asks for a tree or a file not yet wired has not seen every source: a
    /// compile now would be of a partial source set, published as a module its importers
    /// compile against and then compile again.
    func test_aRunThatFindsSomethingNewDoesNotCompile() throws {
        var input = try makeInput(folder: try manifest("input:/pkg/GRDB", [file("Fixits.swift"), folder("Core")]),
                                  treeArrived: false).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/pkg/GRDB/Fixits.swift": .value(try "// fixits".intern())]

        let output = try makeTool().process(input: ProcessInput(inputValues: input))

        XCTAssertTrue(executor.invocations.isEmpty, "swiftc ran on a partial source set")
        XCTAssertEqual(try treeSpecs(output).keys.sorted(), ["input:/pkg/GRDB"])
        for port in [SwiftCompiler.outputObject, SwiftCompiler.outputModule] {
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

    func test_doesNotReadIntoSubfoldersOutsideAnExplicitSourcesList() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/semel", [file("main.swift"), folder("Tests")]),
            subfolders: ["input:/pkg/semel/Tests": try manifest("input:/pkg/semel/Tests", [file("Test.swift")])],
            extraConfiguration: ["sourcePaths=main.swift"]))

        XCTAssertEqual(try sourceSpecs(output), ["input:/pkg/semel/main.swift"])
    }

    /// A listed source path may sit inside a subfolder, so the tree is still read through
    /// that subfolder's ancestors to reach it, and no further.
    func test_readsIntoASubfolderThatLeadsToAListedSourcePath() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/target", [folder("Core"), folder("Ignored")]),
            subfolders: ["input:/pkg/target/Core":    try manifest("input:/pkg/target/Core", [file("Thing.swift"), file("Other.swift")]),
                         "input:/pkg/target/Ignored": try manifest("input:/pkg/target/Ignored", [file("Thing.swift")])],
            extraConfiguration: ["sourcePaths=Core/Thing.swift"]))

        XCTAssertEqual(try sourceSpecs(output), ["input:/pkg/target/Core/Thing.swift"])
    }

    /// A documentation catalog is one item to SwiftPM, never sources: SwiftTreeSitter keeps a
    /// tutorial's `Package.swift` in its `Documentation.docc`, which imports
    /// `PackageDescription` and failed the target's compile when it was taken (B-77).
    func test_doesNotTakeSourcesFromADocumentationCatalog() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/SwiftTreeSitter", [file("Parser.swift"), folder("Documentation.docc")]),
            subfolders: ["input:/pkg/SwiftTreeSitter/Documentation.docc":
                            try manifest("input:/pkg/SwiftTreeSitter/Documentation.docc", [folder("Code")]),
                         "input:/pkg/SwiftTreeSitter/Documentation.docc/Code":
                            try manifest("input:/pkg/SwiftTreeSitter/Documentation.docc/Code", [file("package.swift")])]))

        XCTAssertEqual(try sourceSpecs(output), ["input:/pkg/SwiftTreeSitter/Parser.swift"])
    }

    func test_skipsExcludedPaths() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/target", [file("Keep.swift"), file("Drop.swift"), folder("Vendor")]),
            subfolders: ["input:/pkg/target/Vendor": try manifest("input:/pkg/target/Vendor", [file("Vendored.swift")])],
            extraConfiguration: ["excludedPaths=Drop.swift,Vendor"]))

        XCTAssertEqual(try sourceSpecs(output), ["input:/pkg/target/Keep.swift"])
    }

    /// A flat target compiles on the run after its first, as it did before the tree: the
    /// first asks for its files and its tree together, and the tree adds nothing.
    func test_aFlatSourceFolderCompilesOnTheRunAfterItsFirst() throws {
        var input = try makeInput(folder: try manifest("input:/pkg/Sources/MyLibraryTargetA", [file("Thing.swift")]),
                                  treeArrived: false).inputValues
        let first = try makeTool().process(input: ProcessInput(inputValues: input))
        XCTAssertEqual(try sourceSpecs(first), ["input:/pkg/Sources/MyLibraryTargetA/Thing.swift"])
        XCTAssertEqual(try treeSpecs(first).keys.sorted(), ["input:/pkg/Sources/MyLibraryTargetA"])

        input = try makeInput(folder: try manifest("input:/pkg/Sources/MyLibraryTargetA", [file("Thing.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/pkg/Sources/MyLibraryTargetA/Thing.swift": .value(try "// thing".intern())]
        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        XCTAssertEqual(executor.lastArguments.filter { $0.hasSuffix(".swift") }, ["input:/pkg/Sources/MyLibraryTargetA/Thing.swift"])
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
            SwiftCompiler.bridgingHeader:        [:],
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

    // MARK: - Package macros (B-80)

    /// Each macro executable is laid in the sandbox under `macros/` at its module's name,
    /// executable, and loaded by that relative path for the module it implements — never
    /// an absolute one, which would name the sandbox — ordered by module however the wires
    /// arrive.
    func test_eachMacroExecutableIsLaidUnderMacrosAndLoadedForItsModule() throws {
        var input = try makeInput(folder: try manifest("input:/pkg/Sources/App", [file("App.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/pkg/Sources/App/App.swift": .value(try "let x = 1".intern())]
        input[SwiftCompiler.macroExecutables] = ["StringifyMacros":  .value(try "stringify".intern()),
                                                 "DependencyMacros": .value(try "dependency".intern())]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        let arguments = executor.lastArguments
        let loaded = arguments.indices.filter { arguments[$0] == "-load-plugin-executable" }.map { arguments[$0 + 1] }
        XCTAssertEqual(loaded, ["macros/DependencyMacros#DependencyMacros", "macros/StringifyMacros#StringifyMacros"])
        XCTAssertFalse(arguments.contains("-external-plugin-path"), "\(arguments)")
        let invocation = try XCTUnwrap(executor.invocations.last)
        XCTAssertEqual(invocation.inputFileNames.filter { $0.hasPrefix("macros/") }.sorted(),
                       ["macros/DependencyMacros", "macros/StringifyMacros"])
        XCTAssertEqual(invocation.inputFileModes["macros/StringifyMacros"], FileMetadata.executableMode)
    }

    /// A target that uses no package macro loads none: a toolchain's macros are found by
    /// the driver's own plugin paths.
    func test_aTargetUsingNoPackageMacroLoadsNone() throws {
        var input = try makeInput(folder: try manifest("input:/pkg/Sources/App", [file("App.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/pkg/Sources/App/App.swift": .value(try "let x = 1".intern())]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        XCTAssertFalse(executor.lastArguments.contains("-load-plugin-executable"), "\(executor.lastArguments)")
        XCTAssertFalse(executor.lastArguments.contains("-plugin-path"), "\(executor.lastArguments)")
    }

    func test_aTargetWithoutABridgingHeaderImportsNoObjectiveC() throws {
        var input = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "let x = 1".intern())]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        XCTAssertFalse(executor.lastArguments.contains("-import-objc-header"), "\(executor.lastArguments)")
    }

    /// A module and an object, no interface: SwiftPM writes one only with library
    /// evolution, and swiftc warns that one wants it — an error under a package target's
    /// `-warnings-as-errors`, which stopped NetNewsWire's `RSWeb` (B-77). With a bridging
    /// header, too, which swiftc refuses an interface for anyway.
    func test_aModuleIsWrittenWithNoInterface() throws {
        var input = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")])).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "let x = 1".intern())]

        for processInput in [ProcessInput(inputValues: input), try bridgingInput()] {
            _ = try makeTool().process(input: processInput)

            XCTAssertFalse(executor.lastArguments.contains("-emit-module-interface"), "\(executor.lastArguments)")
            XCTAssertTrue(executor.lastArguments.contains("-emit-module"), "\(executor.lastArguments)")
            XCTAssertEqual(executor.invocations.last?.expectedOutputFileNames, ["GRDB.o", "GRDB.swiftmodule"])
        }
    }

    // MARK: - What a rejected argument says (B-98)

    // swiftc's complaint names the argument it rejected and never the setting that produced
    // it. The failed output carries swiftc's text, and the key behind it as the remedy.

    private func failureDocument(_ output: ProcessOutput, port: String) throws -> ErrorDocument {
        try XCTUnwrap(output.outputValues[port]?.errorDocument,
                      "expected an error on \(port), got \(String(describing: output.outputValues[port]))")
    }

    func test_aTripleSwiftcRejectsIsReportedWithTheSettingItCameFrom() throws {
        executor.exitCode = 1
        executor.errorOutput = "error: unknown target 'nonsense'"

        var input = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")]),
                                  extraConfiguration: ["target=nonsense"]).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "// app".intern())]

        let output = try makeTool().process(input: ProcessInput(inputValues: input))

        let document = try failureDocument(output, port: SwiftCompiler.outputObject)
        XCTAssertEqual(document.diagnostic, .tool(text: "error: unknown target 'nonsense'", tool: "swiftc"))
        XCTAssertEqual(document.remedy, .setting(keys: ["swift.compiler.target"]))
        XCTAssertEqual(document.subject, .target(name: "GRDB"), "a compile belongs to the module it builds")
    }

    /// The SDK reaches the command line as the path xcrun resolved the name to, so the
    /// remedy is the only place the key the config file states appears.
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

        XCTAssertEqual(try failureDocument(output, port: SwiftCompiler.outputObject).remedy,
                       .setting(keys: ["swift.compiler.sdk"]))
    }

    /// An error in the source is about the source: nothing is added.
    func test_anErrorInTheSourceNamesNoSetting() throws {
        executor.exitCode = 1
        executor.errorOutput = "input:/app/Sources/App.swift:1:1: error: cannot find 'foo' in scope"

        var input = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")]),
                                  extraConfiguration: ["target=arm64-apple-macos14.0"]).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "foo()".intern())]

        let output = try makeTool().process(input: ProcessInput(inputValues: input))

        let document = try failureDocument(output, port: SwiftCompiler.outputObject)
        XCTAssertEqual(document.diagnostic, .tool(text: "input:/app/Sources/App.swift:1:1: error: cannot find 'foo' in scope",
                                                  tool: "swiftc"))
        XCTAssertNil(document.remedy)
    }

    // MARK: - A package target's Swift settings

    /// A package target's `swiftSettings`, as the converter carries them (B-77): each
    /// feature its flag, each define a `-D`, and the unsafe flags as they stand after the
    /// sources — a JSON list, so a flag holding a comma arrives whole.
    func test_aTargetsSwiftSettingsReachTheCommandLine() throws {
        let unsafeFlags = try SwiftCompilerConfiguration.encodedFlagList(["-warnings-as-errors", "-Xcc", "-Wl,-a,-b"])
        var input = try makeInput(folder: try manifest("input:/ext/Sources", [file("Main.swift")]),
                                  extraConfiguration: [
                                      "languageMode=6",
                                      "upcomingFeatures=NonisolatedNonsendingByDefault,InferIsolatedConformances",
                                      "experimentalFeatures=StrictConcurrency",
                                      "defines=FOO,BAR",
                                      "unsafeFlags=\(unsafeFlags)",
                                  ]).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/ext/Sources/Main.swift": .value(try "// main".intern())]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        let arguments = executor.lastArguments
        let modeIndex = try XCTUnwrap(arguments.firstIndex(of: "-swift-version"), "\(arguments)")
        XCTAssertEqual(Array(arguments[modeIndex...].prefix(12)), [
            "-swift-version", "6",
            "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
            "-enable-upcoming-feature", "InferIsolatedConformances",
            "-enable-experimental-feature", "StrictConcurrency",
            "-D", "FOO",
            "-D", "BAR",
        ])
        let sourceIndex = try XCTUnwrap(arguments.firstIndex(of: "input:/ext/Sources/Main.swift"), "\(arguments)")
        XCTAssertEqual(Array(arguments[(sourceIndex + 1)...]), ["-warnings-as-errors", "-Xcc", "-Wl,-a,-b"])
    }

    /// A package target is compiled in its package, as SwiftPM compiles it, so that a
    /// `package` declaration — CodeEditTextView's `package(set) public var textStorage` —
    /// is seen by the package's other targets (B-77). An app's target names none.
    func test_aPackageTargetIsCompiledWithItsPackagesName() throws {
        var input = try makeInput(folder: try manifest("input:/ext/Sources", [file("Main.swift")]),
                                  extraConfiguration: ["packageName=CodeEditTextView"]).inputValues
        input[SwiftCompiler.inputSourceFiles] = ["input:/ext/Sources/Main.swift": .value(try "// main".intern())]

        _ = try makeTool().process(input: ProcessInput(inputValues: input))

        let arguments = executor.lastArguments
        let moduleIndex = try XCTUnwrap(arguments.firstIndex(of: "-module-name"), "\(arguments)")
        XCTAssertEqual(Array(arguments[moduleIndex...].prefix(4)), ["-module-name", "GRDB", "-package-name", "CodeEditTextView"])

        var appInput = try makeInput(folder: try manifest("input:/app/Sources", [file("App.swift")])).inputValues
        appInput[SwiftCompiler.inputSourceFiles] = ["input:/app/Sources/App.swift": .value(try "// app".intern())]
        _ = try makeTool().process(input: ProcessInput(inputValues: appInput))
        XCTAssertFalse(executor.lastArguments.contains("-package-name"), "\(executor.lastArguments)")
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
            XCTAssertEqual(error as? ErrorCondition,
                           .settingNotAccepted(key: "swift.compiler.optimisationLevel", value: "-Ofast",
                                               accepted: ["none", "speed", "size"]))
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

    /// No settings, no flags: every compile built before them keeps its command line.
    func test_noSwiftSettingsAddNoFlags() throws {
        let configuration = try self.configuration([:])
        XCTAssertEqual(configuration.upcomingFeatures, [])
        XCTAssertEqual(configuration.experimentalFeatures, [])
        XCTAssertEqual(configuration.defines, [])
        XCTAssertEqual(configuration.unsafeFlags, [])
    }

    func test_unsafeFlagsThatAreNotAJSONListAreRefusedByName() {
        XCTAssertThrowsError(try configuration(["unsafeFlags": "-warnings-as-errors"])) { error in
            XCTAssertTrue("\(error)".contains("swift.compiler.unsafeFlags"), "got \(error)")
        }
    }

    /// An iOS package names its SDK and target; both reach the command line.
    func test_aDeclaredSDKAndTargetAreCarried() throws {
        let configuration = try self.configuration(["sdk": "iphonesimulator",
                                                    "target": "arm64-apple-ios18.0-simulator"])

        XCTAssertEqual(configuration.sdk, "iphonesimulator")
        XCTAssertEqual(configuration.target, "arm64-apple-ios18.0-simulator")
    }
}
