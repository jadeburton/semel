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
        let material = try tool.buildCacheKeyMaterial(input: input)
        let key      = try material.cacheKey()
        let output = ProcessOutput(
            outputValues: [SampleTool.output: .value(try "OBJECT".intern()),
                           SampleTool.errorLog: .value(""),
                           SampleTool.infoLog: .value("")],
            inputWireSpecs: [:])
        try tool.saveCacheForAllInputsAndOutputs(keyMaterial: material, processingDuration: 0.1,
                                                 output: AppliedOutput(folding: output))
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

    /// A directory of its own, removed when the test ends, so a test that writes archives
    /// beside a database leaves nothing behind.
    private func makeTemporaryDatabasePath() throws -> String {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("graph.sqlite").path
    }

    /// An engine over a database on disk, which is what an archive needs. Opening another
    /// database reassigns `DatabaseLayer.shared`, so whatever the suite set is put back.
    private func makeFileBackedEngine(at path: String) throws -> BuildEngine {
        let sharedDatabase = DatabaseLayer.shared
        let sharedEngine   = BuildEngine.shared
        addTeardownBlock {
            DatabaseLayer.shared = sharedDatabase
            BuildEngine.shared   = sharedEngine
        }
        let fileEngine = try BuildEngine(database: try DatabaseLayer(filePath: path),
                                         startProcessingLoop: false)
        BuildEngine.shared = fileEngine
        return fileEngine
    }

    @discardableResult
    private func makeDerivedNode(role: String) throws -> ObjectID {
        let (node, _) = try GraphSpecNode.parse("SettingsLiteral(role: '\(role)').output").findOrCreateMatchingNode()
        return try node.requireID()
    }

    /// A reset is the moment the state that made it necessary is destroyed. The file is
    /// copied aside first, beside the original, and the caller is told where — otherwise
    /// the bug that prompted the reset is unreadable afterwards.
    func test_reset_copiesTheGraphAsideAndNamesTheCopy() throws {
        let path       = try makeTemporaryDatabasePath()
        let fileEngine = try makeFileBackedEngine(at: path)
        let doomedID   = try makeDerivedNode(role: "doomed")

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

    /// Two resets in quick succession take two copies under the same timestamp, and the
    /// first one holds the more: it was taken before the first reset emptied the graph.
    /// Overwriting it would destroy exactly the evidence this feature is for.
    func test_reset_neverOverwritesAnEarlierCopy() throws {
        let path       = try makeTemporaryDatabasePath()
        let fileEngine = try makeFileBackedEngine(at: path)

        try makeDerivedNode(role: "first")
        let firstArchive = try XCTUnwrap(fileEngine.reset())
        try makeDerivedNode(role: "second")
        let secondArchive = try XCTUnwrap(fileEngine.reset())

        XCTAssertNotEqual(firstArchive, secondArchive, "a second copy is a second file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstArchive),
                      "the earlier copy survives the later reset")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondArchive))
    }

    /// A reset that discards nothing — a fresh home, where the graph holds the input root,
    /// the output root and ProjectFinder and nothing else — has no evidence to keep, and
    /// littering the home with copies of an empty database helps nobody.
    func test_reset_onAGraphWithNothingDerived_takesNoCopy() throws {
        let path       = try makeTemporaryDatabasePath()
        let fileEngine = try makeFileBackedEngine(at: path)

        XCTAssertNil(try fileEngine.reset(), "nothing was discarded, so nothing was copied")

        let leftBehind = try FileManager.default
            .contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
            .filter { $0.contains(".broken-") }
        XCTAssertEqual(leftBehind, [], "a fresh home is left as it was")
    }

    /// The cache is state in the same file, so discarding it is worth a copy even when
    /// there is no derived node left to delete.
    func test_resetClearingTheCache_copiesTheGraphAsideEvenWithNothingToDelete() throws {
        let path       = try makeTemporaryDatabasePath()
        let fileEngine = try makeFileBackedEngine(at: path)
        try cacheOneBuiltOutput()
        _ = try fileEngine.reset()   // leaves the graph clean and the cache full

        XCTAssertNotNil(try fileEngine.reset(clearCache: true),
                        "the cache about to be discarded is state worth copying")
    }

    /// A home that cannot be written to is one of the conditions a repair command is typed
    /// under, so the copy is the first thing that meets it. The reset stops there, with the
    /// graph untouched, and the message names the copy, the file it tried to write and the
    /// machine's failure underneath — not a bare SQLite code.
    func test_reset_whenTheCopyCannotBeWritten_stopsAndSaysSo() throws {
        let path       = try makeTemporaryDatabasePath()
        let fileEngine = try makeFileBackedEngine(at: path)
        let doomedID   = try makeDerivedNode(role: "doomed")

        let home = (path as NSString).deletingLastPathComponent
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home)
        }

        XCTAssertThrowsError(try fileEngine.reset()) { error in
            guard let failure = error as? GraphCopyFailedError else {
                return XCTFail("expected GraphCopyFailedError, got \(error)")
            }
            XCTAssertTrue(failure.destinationPath.hasPrefix(path + ".broken-"))
            XCTAssertTrue(failure.unrecoverableDescription.contains(failure.destinationPath),
                          failure.unrecoverableDescription)
            XCTAssertTrue(failure.unrecoverableDescription.contains("nothing was reset"),
                          failure.unrecoverableDescription)
            guard let volume = failure.underlying as? DatabaseVolumeError else {
                return XCTFail("the machine's failure, told apart at the database layer's "
                             + "boundary, got \(failure.underlying)")
            }
            // The file that could not be written is the copy, not the database being read
            // from, and a message naming the live graph would send the reader to the wrong
            // file.
            XCTAssertEqual(volume.filePath, failure.destinationPath,
                           "the nested error names the copy, not the graph it was read from")
            XCTAssertTrue(volume.unrecoverableDescription.contains(failure.destinationPath),
                          volume.unrecoverableDescription)
        }

        XCTAssertNotNil(try fileEngine.database.node.find(nodeID: doomedID),
                        "a reset that could not keep the evidence deletes nothing")
    }

    /// An in-memory graph has no file, so there is nothing to copy and nothing to name.
    func test_reset_onAnInMemoryGraph_namesNoCopy() throws {
        try makeDerivedNode(role: "doomed")

        XCTAssertNil(try engine.reset())
    }

    /// The name has to sort by age and survive being copied anywhere, which is what the
    /// colon-free UTC form buys. Pinned, because a formatter option is easy to change and
    /// the cost is silent.
    func test_theArchiveNameCarriesAnISO8601UTCTimestamp() {
        XCTAssertEqual(BuildEngine.archiveTimestamp(Date(timeIntervalSince1970: 1_758_600_000)),
                       "2025-09-23T040000Z")
    }

    // A reset that finds nothing to delete still has to kick off the rebuild —
    // the caller reports "Rebuild started." either way.
    func test_reset_withNothingToDelete_reschedulesProjectFinder() throws {
        // The first reset leaves only the preserved nodes behind, so the second
        // one has an empty delete set.
        try engine.reset()
        try engine.projectFinder.setScheduled(false)

        try engine.reset()

        let projectFinder = try XCTUnwrap(engine.database.node.select(nodeID: try engine.projectFinder.requireID()))
        XCTAssertTrue(projectFinder.scheduled,
                      "reset must reschedule ProjectFinder even when it deleted nothing")
    }

    // `rm` marks an input file for deletion and lets the idle-time GC collect it.
    // A reset in that window must not resurrect the file.
    func test_reset_keepsPendingDeletionMarkOnPreservedInputNode() throws {
        let inputChild = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("src"), pinned: true)
        try engine.database.node.updatePendingDeletion(nodeID: try inputChild.requireID(), pendingDeletion: true)

        // Give reset something to delete, so it reaches the bulk-delete transaction.
        _ = try GraphSpecNode.parse("SettingsLiteral(role: 'doomed').output").findOrCreateMatchingNode()

        try engine.reset()

        let after = try XCTUnwrap(engine.database.node.select(nodeID: try inputChild.requireID()))
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
