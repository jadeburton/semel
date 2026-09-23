//
//  BuildEngineResetTests.swift
//  semel_tests
//

@testable import SemelCore
import Foundation
import XCTest
import SemelNodeKit

/// `reset()` wipes the derived build graph and reschedules ProjectFinder so the
/// whole graph is rebuilt from the current input file system contents.
final class BuildEngineResetTests: SemelCoreTestCase {

    var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - Cache helpers

    /// A node of the shape the cache serves: static and dynamic input ports, output ports,
    /// and an input whose values are what the key is built from.
    private func makeSampleTool() throws -> SampleTool {
        let (node, _) = try GraphSpecNode.parse("SampleTool()").findOrCreateMatchingNode()
        return try SampleTool(thisNode: node)
    }

    private func sampleInput() throws -> ProcessInput {
        let configuration = [
            "toolDescriptor.name": "sample",
            "toolDescriptor.version": "sample tool version 1",
        ].sorted { $0.key < $1.key }
         .map { "\($0.key)=\($0.value)" }
         .joined(separator: "\n")
        return ProcessInput(inputValues: [
            SampleTool.configuration: ["configuration": .value(try configuration.intern())],
            SampleTool.input: ["src/hello.c.p": .value(try "int main(){}".intern())],
        ])
    }

    /// Puts one entry in the cache the way a build does, and answers the key it was
    /// stored under.
    @discardableResult
    private func cacheOneBuiltOutput() throws -> String {
        let tool   = try makeSampleTool()
        let input  = try sampleInput()
        let key    = try XCTUnwrap(tool.buildCacheKeyFromAllInputs(input: input))
        let output = ProcessOutput(
            outputValues: [SampleTool.output: .value(try "OBJECT".intern()),
                           SampleTool.errorLog: .value(""),
                           SampleTool.infoLog: .value("")],
            inputWireSpecs: [:])
        try tool.saveCacheForAllInputsAndOutputs(cacheKey: key, processingDuration: 0.1, output: output)
        XCTAssertNotNil(try tool.loadCachedOutputs(cacheKey: key), "precondition: the build is cached")
        return key
    }

    // MARK: - The cache

    /// The cache is content-addressed and keyed on nothing a node ID knows, so the graph
    /// a reset rebuilds hits every entry the graph it deleted left behind. Deleting them
    /// would buy nothing but a cold build of every project in the home.
    func test_reset_keepsTheCacheSoTheRebuiltGraphHitsIt() throws {
        let key = try cacheOneBuiltOutput()

        try engine.reset()

        // The node the rebuild recreates: a new row, a new ID, the same inputs.
        let rebuilt    = try makeSampleTool()
        let rebuiltKey = try XCTUnwrap(rebuilt.buildCacheKeyFromAllInputs(input: try sampleInput()))
        XCTAssertEqual(rebuiltKey, key, "the key survives the node the entry was built by")

        let hit = try rebuilt.loadCachedOutputs(cacheKey: rebuiltKey)
        XCTAssertEqual(try hit?.outputValues[SampleTool.output]?.expectValue().resolveAsString(),
                       "OBJECT",
                       "reset must keep the cache: the rebuild is a pass of cache hits, not a cold build")
    }

    /// The one thing a cache wipe is for is an entry believed wrong, and that is asked for
    /// explicitly.
    func test_resetClearingTheCache_emptiesIt() throws {
        let key = try cacheOneBuiltOutput()

        try engine.reset(clearCache: true)

        XCTAssertNil(try engine.database.cacheEntry.select(hash: key),
                     "reset --cache is the command that discards cached builds")
    }

    // MARK: - The graph that was discarded

    private func makeTemporaryDatabasePath() throws -> String {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("graph.sqlite").path
    }

    /// A reset is the moment the state that made it necessary is destroyed. The file is
    /// copied aside first, beside the original, and the caller is told where — otherwise
    /// the bug that prompted the reset is unreadable afterwards.
    func test_reset_copiesTheGraphAsideAndNamesTheCopy() throws {
        let path       = try makeTemporaryDatabasePath()
        let database   = try DatabaseLayer(filePath: path)
        let fileEngine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = fileEngine
        let (doomed, _) = try GraphSpecNode.parse("Configuration(role: 'doomed').output").findOrCreateMatchingNode()
        let doomedID = try doomed.requireID()

        let archivedPath = try XCTUnwrap(fileEngine.reset(), "a file-backed graph is copied aside")

        XCTAssertTrue(archivedPath.hasPrefix(path + ".broken-"),
                      "the copy sits beside the original, got: \(archivedPath)")
        XCTAssertNil(try fileEngine.database.node.find(nodeID: doomedID),
                     "precondition: the reset deleted the derived node")

        // The copy is a database in its own right, holding what the reset discarded.
        let archived = try DatabaseLayer(filePath: archivedPath)
        XCTAssertNotNil(try archived.node.find(nodeID: doomedID),
                        "the copy is the evidence: it still holds the node the reset deleted")
    }

    /// An in-memory graph has no file, so there is nothing to copy and nothing to name.
    func test_reset_onAnInMemoryGraph_namesNoCopy() throws {
        XCTAssertNil(try engine.reset())
    }

    // A reset that finds nothing to delete still has to kick off the rebuild —
    // the caller reports "Rebuild started." either way.
    func test_reset_withNothingToDelete_reschedulesProjectFinder() throws {
        // The first reset leaves only the preserved nodes behind, so the second
        // one has an empty delete set.
        try engine.reset()
        try engine.projectFinder.setScheduled(false)

        try engine.reset()

        let projectFinder = try XCTUnwrap(engine.database.node.select(nodeID: try engine.projectFinder.id!))
        XCTAssertTrue(projectFinder.scheduled,
                      "reset must reschedule ProjectFinder even when it deleted nothing")
    }

    // `rm` marks an input file for deletion and lets the idle-time GC collect it.
    // A reset in that window must not resurrect the file.
    func test_reset_keepsPendingDeletionMarkOnPreservedInputNode() throws {
        let inputChild = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("src"), pinned: true)
        try engine.database.node.updatePendingDeletion(nodeID: inputChild.id!, pendingDeletion: true)

        // Give reset something to delete, so it reaches the bulk-delete transaction.
        _ = try GraphSpecNode.parse("Configuration(role: 'doomed').output").findOrCreateMatchingNode()

        try engine.reset()

        let after = try XCTUnwrap(engine.database.node.select(nodeID: inputChild.id!))
        XCTAssertTrue(after.pendingDeletion,
                      "reset must not clear a pending deletion the user asked for")
    }

    // The output root survives a reset but all of its children are deleted, so its
    // manifest has to stop advertising them.
    func test_reset_refreshesPreservedOutputRootManifest() throws {
        let outputRoot = try engine.outputFileSystem
        _ = try outputRoot.ensureEntirePathExistsAsFolders(Path("bin"), pinned: false)

        let before = try outputRoot.readFromOutputPort(Folder.folderManifestOutputPort)
            .expectValue().resolveAsString()
        XCTAssertTrue(before.contains("bin"), "precondition: the manifest lists the child")

        try engine.reset()

        let after = try outputRoot.readFromOutputPort(Folder.folderManifestOutputPort)
            .expectValue().resolveAsString()
        XCTAssertFalse(after.contains("bin"),
                       "reset must refresh the preserved output root's manifest")
    }
}
