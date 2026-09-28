//
//  ArtifactChangeReportingTests.swift
//  SemelCoreTests
//
//  B-50. The user-visible story of a push is: the graph settled, these artifacts
//  appeared, changed, disappeared. The report is the difference between two settles, so
//  a rebuild that publishes the same bytes says nothing at all, and a product that went
//  to pending and back to the value it had says nothing either.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ArtifactChangeReportingTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var captured: [ArtifactChanges] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.artifactReporter = { [weak self] changes in self?.captured.append(changes) }
        // The first report of a launch reconciles the whole table; taking that one here
        // leaves every test below on the steady path, which is the one the design is
        // about. `test_theFirstReportOfALaunchReconcilesTheWholeTable` covers the other.
        engine.reportArtifactChanges()
        captured = []
    }

    override func tearDown() {
        engine = nil
        captured = []
        BuildEngine.shared = nil
        super.tearDown()
    }

    // MARK: - A product, and the source standing in for its builder

    @discardableResult
    private func publishProduct(_ name: String, contents: String) throws -> (source: NodeRecord,
                                                                             product: NodeRecord) {
        try publishProductAt("output:/src/\(name)", from: name, contents: contents)
    }

    /// The same, at a path of the caller's choosing rather than under `output:/src`.
    @discardableResult
    private func publishProductAt(_ path: String, from sourceName: String,
                                  contents: String) throws -> (source: NodeRecord, product: NodeRecord) {
        let sourceTree = GraphSpecNode.staticFile(at: "input:/stand-in/\(sourceName)")
        let (source, _) = try sourceTree.findOrCreateMatchingNode()
        _ = try XCTUnwrap(source.nodeAsAny() as? StaticFile).replaceContent(try contents.intern())
        let (product, _) = try product(at: path, reading: sourceTree).findOrCreateMatchingNode()
        return (source, product)
    }

    /// `OutputFile(path:, input: ['product': <input>])`.
    private func product(at path: String, reading input: GraphSpecNode) -> GraphSpecNode {
        GraphSpecNode(OutputFile.self, properties: [OutputFile.pathProperty: path],
                      inputs: [OutputFile.inputPort: ["product": input]])
    }

    private func rewrite(_ source: NodeRecord, to contents: String) throws {
        _ = try XCTUnwrap(source.nodeAsAny() as? StaticFile).replaceContent(try contents.intern())
    }

    private func onlyReport() throws -> ArtifactChanges {
        XCTAssertEqual(captured.count, 1, "one settle, one report")
        return try XCTUnwrap(captured.first)
    }

    // MARK: - The five cases

    func test_aColdBuildReportsEveryProductAsAppeared() throws {
        try publishProduct("lib.a", contents: "archive")
        try publishProduct("app", contents: "binary")

        engine.reportArtifactChanges()

        XCTAssertEqual(try onlyReport(), ArtifactChanges(appeared: ["output:/src/app", "output:/src/lib.a"]))
    }

    func test_anIdenticalRebuildReportsNothing() throws {
        let published = try publishProduct("lib.a", contents: "archive")
        engine.reportArtifactChanges()
        captured = []

        try rewrite(published.source, to: "archive")
        engine.reportArtifactChanges()

        XCTAssertTrue(captured.isEmpty, "the same bytes are not news, got \(captured)")
    }

    func test_aContentChangeReportsOneChangedPath() throws {
        let published = try publishProduct("lib.a", contents: "archive")
        try publishProduct("app", contents: "binary")
        engine.reportArtifactChanges()
        captured = []

        try rewrite(published.source, to: "a different archive")
        engine.reportArtifactChanges()

        XCTAssertEqual(try onlyReport(), ArtifactChanges(changed: ["output:/src/lib.a"]))
    }

    func test_aRemovalReportsOneDisappearedPath() throws {
        let published = try publishProduct("lib.a", contents: "archive")
        try publishProduct("app", contents: "binary")
        engine.reportArtifactChanges()
        captured = []

        try engine.database.node.updatePendingDeletion(nodeID: try published.product.requireID(),
                                                       pendingDeletion: true)
        try engine.processPendingDeletions()
        engine.reportArtifactChanges()

        XCTAssertEqual(try onlyReport(), ArtifactChanges(disappeared: ["output:/src/lib.a"]))
    }

    /// The case the whole diff exists for: a push wakes the product, its port goes to
    /// pending and comes back holding what it held before. Mid-flight that is two
    /// transitions; between settles it is nothing.
    func test_aProductThatWentPendingAndBackToTheSameValueReportsNothing() throws {
        let published = try publishProduct("lib.a", contents: "archive")
        engine.reportArtifactChanges()
        captured = []

        try published.source.writeToOutputPort(StaticFile.outputPort, value: .noValue(reason: .pending))
        try published.source.writeToOutputPort(StaticFile.outputPort, value: .value(try "archive".intern()))
        engine.reportArtifactChanges()

        XCTAssertTrue(captured.isEmpty, "value → pending → the same value is not a change, got \(captured)")
    }

    // MARK: - What is not an artifact change

    /// An error is the error report's to tell. The artifact is left as it was last
    /// reported, so the recovery that follows says nothing either — nothing about the
    /// bytes changed between the two settles.
    func test_aProductThatFailedIsNotReportedAsDisappeared() throws {
        let published = try publishProduct("lib.a", contents: "archive")
        engine.reportArtifactChanges()
        captured = []

        try published.source.writeToOutputPort(
            StaticFile.outputPort, value: .noValue(reason: .error(messageDataObjectHash: try "boom".intern())))
        engine.reportArtifactChanges()
        XCTAssertTrue(captured.isEmpty, "a failure is the error report's, got \(captured)")

        try rewrite(published.source, to: "archive")
        engine.reportArtifactChanges()
        XCTAssertTrue(captured.isEmpty, "and so is the recovery, got \(captured)")
    }

    /// A product the graph names and nothing has produced has not appeared.
    func test_aProductWithNoValueYetIsNotReported() throws {
        _ = try product(at: "output:/src/unfed", reading: .staticFile(at: "input:/stand-in/unfed"))
            .findOrCreateMatchingNode()

        engine.reportArtifactChanges()

        XCTAssertTrue(captured.isEmpty, "nothing was published, got \(captured)")
    }

    /// A settle in which no product moved says nothing, the way a settle that scheduled
    /// nothing prints no summary.
    func test_aSettleWithNoArtifactChangesReportsNothing() throws {
        engine.reportArtifactChanges()

        XCTAssertTrue(captured.isEmpty)
    }

    // MARK: - The table

    /// The snapshot is what the next settle is compared against, so it has to hold the
    /// hash that was reported — in the graph's own database, where a client told
    /// "appeared" can find the artifact.
    func test_theReportedHashIsRecordedInTheGraphsOwnDatabase() throws {
        try publishProduct("lib.a", contents: "archive")

        engine.reportArtifactChanges()

        let recorded = try engine.database.artifactSnapshot.select(path: "output:/src/lib.a")
        XCTAssertEqual(recorded?.contentHash, try "archive".intern())
    }

    func test_aDisappearedArtifactLeavesNoRowBehind() throws {
        let published = try publishProduct("lib.a", contents: "archive")
        engine.reportArtifactChanges()

        try engine.database.node.updatePendingDeletion(nodeID: try published.product.requireID(),
                                                       pendingDeletion: true)
        try engine.processPendingDeletions()
        engine.reportArtifactChanges()

        XCTAssertNil(try engine.database.artifactSnapshot.select(path: "output:/src/lib.a"))
    }

    /// A restart loses the touched set, so the first report of a launch walks the table
    /// instead. What it finds unchanged is still not news.
    func test_theFirstReportOfALaunchReconcilesTheWholeTable() throws {
        try publishProduct("lib.a", contents: "archive")
        engine.reportArtifactChanges()
        captured = []

        // A second engine over the same database is what a restart looks like: the graph
        // and the snapshots are on disk, the touched set is not.
        let restarted = try BuildEngine(database: engine.database, startProcessingLoop: false)
        BuildEngine.shared = restarted
        var afterRestart: [ArtifactChanges] = []
        restarted.artifactReporter = { afterRestart.append($0) }

        restarted.reportArtifactChanges()

        XCTAssertTrue(afterRestart.isEmpty, "the table already says what was reported, got \(afterRestart)")
    }

    /// And what the touched set would have caught, had it survived, the reconciliation
    /// catches instead.
    func test_theReconciliationReportsWhatChangedWhileNothingWasWatching() throws {
        let published = try publishProduct("lib.a", contents: "archive")
        engine.reportArtifactChanges()

        let restarted = try BuildEngine(database: engine.database, startProcessingLoop: false)
        BuildEngine.shared = restarted
        var afterRestart: [ArtifactChanges] = []
        restarted.artifactReporter = { afterRestart.append($0) }
        try rewrite(published.source, to: "a different archive")

        restarted.reportArtifactChanges()

        XCTAssertEqual(afterRestart, [ArtifactChanges(changed: ["output:/src/lib.a"])])
    }

    // MARK: - The whole diff, once

    /// One settle, one diff, over every artifact: narrowing it is the subscriber's, at
    /// delivery. Pinned because the candidates are consumed as they are read, so a
    /// report that filtered here would swallow everything outside its subtree.
    func test_oneSettlesDiffCoversEveryArtifactWhereverItIs() throws {
        try publishProduct("lib.a", contents: "archive")
        try publishProductAt("output:/elsewhere/other", from: "other", contents: "other")

        engine.reportArtifactChanges()

        XCTAssertEqual(try onlyReport(),
                       ArtifactChanges(appeared: ["output:/elsewhere/other", "output:/src/lib.a"]))
    }

    // MARK: - A delete that did not happen

    /// The collection is recorded before the node is deleted, so a delete that fails must
    /// not be announced: a live product the reader believes is gone would stay that way,
    /// because nothing will wake that node again.
    func test_aProductWhoseDeleteFailedIsNotReportedAsDisappeared() throws {
        let published = try publishProduct("lib.a", contents: "archive")
        engine.reportArtifactChanges()
        captured = []

        // What `processPendingDeletions` records on its way to a delete, without the
        // delete: the node is still there.
        engine.noteArtifactCollected(path: "output:/src/lib.a", nodeID: try published.product.requireID())
        engine.reportArtifactChanges()

        XCTAssertTrue(captured.isEmpty, "the node is still there, got \(captured)")
        XCTAssertNotNil(try engine.database.artifactSnapshot.select(path: "output:/src/lib.a"),
                        "and the row it was last told about stays")
    }

    /// A product collected and rebuilt inside one settle has not disappeared, even while
    /// the rebuilt node has no value yet: there is an `OutputFile` at that path, and the
    /// flapping pair of lines is what the diff exists to remove.
    func test_aProductCollectedAndRebuiltInOneSettleDoesNotFlap() throws {
        let published = try publishProduct("lib.a", contents: "archive")
        engine.reportArtifactChanges()
        captured = []

        try engine.database.node.updatePendingDeletion(nodeID: try published.product.requireID(),
                                                       pendingDeletion: true)
        try engine.processPendingDeletions()
        // Rebuilt, and not yet fed: exactly the window the flap lived in.
        _ = try product(at: "output:/src/lib.a", reading: .staticFile(at: "input:/stand-in/lib.a"))
            .findOrCreateMatchingNode()
        try published.source.writeToOutputPort(StaticFile.outputPort, value: .noValue(reason: .pending))

        engine.reportArtifactChanges()

        XCTAssertTrue(captured.isEmpty, "the product is being rebuilt, not gone, got \(captured)")
        XCTAssertNotNil(try engine.database.artifactSnapshot.select(path: "output:/src/lib.a"))
    }
}
