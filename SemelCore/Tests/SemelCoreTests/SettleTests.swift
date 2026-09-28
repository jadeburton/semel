//
//  SettleTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// B-57. A command returns while the build runs behind it, so a script has to be able to
/// wait for the graph to settle: every scheduled node processed and nothing asking for
/// another pass. These run a real processing loop, which the other engine tests avoid.
final class SettleTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.startProcessingLoop()
    }

    override func tearDown() {
        // A loop left running would keep processing against the next test's globals.
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    /// The same sequence `FilePlugin.handlePush` runs per file.
    private func push(_ relativePath: String, contents: String) throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(
                Path(relativePath).deletingLastComponent ?? .empty, pinned: true)
        let fullPath = Path(Folder.inputFileSystemName) / Path(relativePath)
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(fullPath.string)')").findOrCreateMatchingNode()
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
        _ = try file.replaceContent(try contents.intern())
    }

    private func dirtyManifests() throws -> [String] {
        try engine.database.metadata.selectKeys(withPrefix: Folder.manifestDirtyKeyPrefix)
    }

    func test_anEngineWithNoLoopSettlesAtOnce() async throws {
        // On the same database: a fresh one would become the process-wide database while
        // the running loop still selects from this one, and it would never settle.
        let quiet = try BuildEngine(database: engine.database, startProcessingLoop: false)

        await quiet.waitUntilIdle()   // must not hang: there is nothing to wait for
    }

    /// The first wait returns once the loop has processed what construction scheduled.
    func test_aFreshLoopSettles() async throws {
        await engine.waitUntilIdle()

        XCTAssertTrue(try dirtyManifests().isEmpty)
    }

    /// A push marks its folder dirty and asks for a pass through a Task; a waiter that
    /// started before that Task delivered must still see the pass through, not return on
    /// the idle mark the push interrupted.
    func test_waitingAfterAPushSpansThePassThePushAskedFor() async throws {
        await engine.waitUntilIdle()
        try push("src/main.c", contents: "int main(void) { return 0; }")
        XCTAssertFalse(try dirtyManifests().isEmpty, "precondition: the push left a manifest to rebuild")

        await engine.waitUntilIdle()

        XCTAssertTrue(try dirtyManifests().isEmpty, "the pass the push asked for has run")
        let finder = try engine.database.node.select(nodeID: try engine.projectFinder.requireID())
        XCTAssertFalse(finder.scheduled, "and nothing is left scheduled")
    }

    /// The loop consumed its wake-ups and then marked itself busy, with an actor hop
    /// between: a waiter landing in that gap found the loop idle with nothing outstanding
    /// and returned before the pass had run. A batch end is what a push does and what the
    /// settle-report tests do, and many rounds because the gap is a few instructions wide
    /// — a loaded machine landed in it where a quiet one never did.
    func test_aWaiterNeverSlipsBetweenTheWakeUpAndThePassItAsksFor() throws {
        for round in 0..<200 {
            engine.beginBatch()
            try push("src/file\(round).c", contents: "int value\(round)(void) { return \(round); }")
            engine.endBatch()

            engine.waitUntilIdleBlocking()

            XCTAssertTrue(try dirtyManifests().isEmpty, "round \(round): the wait returned before the pass ran")
        }
    }

    /// The synchronous form a REPL command uses: blocks the calling thread, not the loop.
    func test_theBlockingFormReturnsOnceSettled() throws {
        try push("src/main.c", contents: "int main(void) { return 0; }")

        engine.waitUntilIdleBlocking()

        XCTAssertTrue(try dirtyManifests().isEmpty)
    }
}
