//
//  SwiftCompilerToolTests.swift
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

final class SwiftCompilerToolTests: SemelSwiftTestCase {

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

    private func makeTool() throws -> SwiftCompilerTool {
        try SwiftCompilerTool(thisNode: NodeRecord(id: 1, kind: SwiftCompilerTool.kind))
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
            SwiftCompilerTool.configuration:   ["config": .value(try configuration.intern())],
            SwiftCompilerTool.inputFolder:     ["folder0": rootFolder],
            SwiftCompilerTool.inputSubfolders: subfolders,
        ])
    }

    private func sourceExpectations(_ output: ProcessOutput) throws -> [String] {
        try XCTUnwrap(output.inputWireExpectations[SwiftCompilerTool.inputSourceFiles]).keys.sorted()
    }

    private func subfolderExpectations(_ output: ProcessOutput) throws -> [String: String] {
        try XCTUnwrap(output.inputWireExpectations[SwiftCompilerTool.inputSubfolders])
    }

    // MARK: - Subfolder discovery

    func test_asksForAManifestForEachSubfolderOfTheSourceFolder() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [file("Fixits.swift"), folder("Core"), folder("Record")])))

        XCTAssertEqual(try subfolderExpectations(output),
                       ["input:/pkg/GRDB/Core":   "Folder(path: 'input:/pkg/GRDB/Core').manifest",
                        "input:/pkg/GRDB/Record": "Folder(path: 'input:/pkg/GRDB/Record').manifest"])
    }

    /// The walk goes one level per run, so a grandchild is only requested once its
    /// parent's manifest has arrived. Without this the tree stops at depth one.
    func test_asksForNestedSubfoldersOnceTheirParentManifestHasArrived() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [folder("Core")]),
            subfolders: ["input:/pkg/GRDB/Core": try manifest("input:/pkg/GRDB/Core", [folder("Support")])]))

        XCTAssertEqual(try subfolderExpectations(output)["input:/pkg/GRDB/Core/Support"],
                       "Folder(path: 'input:/pkg/GRDB/Core/Support').manifest")
    }

    /// An unpinned folder is a ghost — the user deleted it or never pushed it. Watching
    /// one would resurrect it, which is what ProjectFinder's isPinned check avoids too.
    func test_doesNotAskForManifestsForUnpinnedSubfolders() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [.init(name: "Core", isFolder: true, isPinned: false)])))

        XCTAssertEqual(try subfolderExpectations(output), [:])
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

        XCTAssertEqual(try sourceExpectations(output),
                       ["input:/pkg/GRDB/Core/Configuration.swift",
                        "input:/pkg/GRDB/Core/Database.swift",
                        "input:/pkg/GRDB/Fixits.swift"])
    }

    func test_ignoresNonSwiftFilesInsideSubfolders() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [folder("Core")]),
            subfolders: ["input:/pkg/GRDB/Core": try manifest("input:/pkg/GRDB/Core",
                                                              [file("Configuration.swift"), file("PrivacyInfo.xcprivacy")])]))

        XCTAssertEqual(try sourceExpectations(output), ["input:/pkg/GRDB/Core/Configuration.swift"])
    }

    func test_ignoresUnpinnedSwiftFilesInsideSubfolders() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/GRDB", [folder("Core")]),
            subfolders: ["input:/pkg/GRDB/Core": try manifest("input:/pkg/GRDB/Core",
                                                              [.init(name: "Gone.swift", isFolder: false, isPinned: false)])]))

        XCTAssertEqual(try sourceExpectations(output), [])
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

        XCTAssertEqual(try sourceExpectations(output), ["input:/pkg/semel/main.swift"])
    }

    func test_doesNotDescendIntoSubfoldersOutsideAnExplicitSourcesList() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/semel", [file("main.swift"), folder("Tests")]),
            extraConfiguration: ["sourcePaths=main.swift"]))

        XCTAssertEqual(try subfolderExpectations(output), [:])
    }

    /// A listed source path may sit inside a subfolder, so the walk still has to descend
    /// through that subfolder's ancestors to reach it.
    func test_descendsIntoASubfolderThatLeadsToAListedSourcePath() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/target", [folder("Core"), folder("Ignored")]),
            extraConfiguration: ["sourcePaths=Core/Thing.swift"]))

        XCTAssertEqual(try subfolderExpectations(output).keys.sorted(), ["input:/pkg/target/Core"])
    }

    func test_skipsExcludedPaths() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/target", [file("Keep.swift"), file("Drop.swift"), folder("Vendor")]),
            extraConfiguration: ["excludedPaths=Drop.swift,Vendor"]))

        XCTAssertEqual(try sourceExpectations(output), ["input:/pkg/target/Keep.swift"])
        XCTAssertEqual(try subfolderExpectations(output), [:])
    }

    /// A flat target must keep behaving exactly as it did before the walk existed —
    /// this is the shape every existing test project has.
    func test_flatSourceFolderStillCompilesItsFilesAndAsksForNoSubfolders() throws {
        let output = try makeTool().process(input: try makeInput(
            folder: try manifest("input:/pkg/Sources/MyLibraryTargetA", [file("Thing.swift")])))

        XCTAssertEqual(try sourceExpectations(output), ["input:/pkg/Sources/MyLibraryTargetA/Thing.swift"])
        XCTAssertEqual(try subfolderExpectations(output), [:])
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
}
