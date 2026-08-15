//
//  BuildEngineResetTests.swift
//  build_system_tests
//

@testable import SemelCore
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
        _ = try GraphShapeNode.parse("Configuration(role: 'doomed').output").findOrCreateMatchingNode()

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
