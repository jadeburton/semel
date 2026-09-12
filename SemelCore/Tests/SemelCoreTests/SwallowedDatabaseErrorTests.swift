//
//  SwallowedDatabaseErrorTests.swift
//  SemelCore
//

@testable import SemelCore
import GRDB
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-52. Thirty-one database calls discarded their errors with `try?`. Inside `reset`'s
/// transaction that meant a failed delete was skipped and the transaction still committed,
/// leaving dangling rows with nothing reported; everywhere it meant a machine failure
/// (B-45's `DatabaseVolumeError`) was dropped before the fatal check could see it.
///
/// The failures here are injected with SQLite triggers, which make one table's deletes
/// fail with a real GRDB error on a real database — the same path a full disk takes,
/// minus the disk.
final class SwallowedDatabaseErrorTests: SemelCoreTestCase {

    private var reported: [any UnrecoverableError] = []
    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        reported = []
        FatalErrors.handler = { [weak self] error in self?.reported.append(error) }
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        FatalErrors.handler = FatalErrors.defaultHandler
        engine = nil
        super.tearDown()
    }

    private func makeDerivedNode() throws -> ObjectID {
        let (node, _) = try GraphSpecNode.parse("Configuration(role: 'doomed').output").findOrCreateMatchingNode()
        return try node.requireID()
    }

    /// Every delete on `table` fails from now on.
    private func failDeletes(on table: String) throws {
        try engine.database.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_\(table)_delete BEFORE DELETE ON \(table)
                BEGIN SELECT RAISE(ABORT, 'simulated delete failure'); END
                """)
        }
    }

    // MARK: - reset is atomic

    /// A delete that fails inside reset's transaction used to be skipped, and the
    /// transaction committed around it. Now the error surfaces and the whole reset rolls
    /// back: the graph is exactly as it was.
    func test_aFailingDeleteRollsTheWholeResetBackAndSurfaces() throws {
        // The roots reset preserves are created on first use; make sure that has happened
        // before counting, or reset's own lookups add them and the count moves for a
        // reason that has nothing to do with the delete.
        _ = try engine.inputFileSystem
        _ = try engine.outputFileSystem
        _ = try engine.projectFinder
        let derived = try makeDerivedNode()
        let before  = try engine.database.node.selectAll().count
        try failDeletes(on: "Node")

        XCTAssertThrowsError(try engine.reset())

        XCTAssertEqual(try engine.database.node.selectAll().count, before, "nothing may be half-deleted")
        XCTAssertNoThrow(try engine.database.node.select(nodeID: derived), "the derived node survives a failed reset")
        XCTAssertTrue(reported.isEmpty, "a constraint failure is the statement's, not the machine's")
    }

    // MARK: - pending deletions

    /// The idle-time collector likewise skipped a failed delete and carried on. It now
    /// throws, so the caller can tell that the pass did not complete.
    func test_aFailingDeleteInThePendingDeletionPassSurfaces() throws {
        let derived = try makeDerivedNode()
        try engine.database.node.updatePendingDeletion(nodeID: derived, pendingDeletion: true)
        try failDeletes(on: "Node")

        XCTAssertThrowsError(try engine.processPendingDeletions())
        XCTAssertNoThrow(try engine.database.node.select(nodeID: derived))
    }

    // MARK: - absence is an answer, failure is not

    func test_findReturnsNilForAMissingNodeAndTheRecordForAPresentOne() throws {
        let derived = try makeDerivedNode()

        XCTAssertNil(try engine.database.node.find(nodeID: 999_999))
        XCTAssertEqual(try engine.database.node.find(nodeID: derived)?.id, derived)
    }

    func test_findStillPropagatesAMachineFailure() {
        XCTAssertThrowsError(try engine.database.withTransaction {
            _ = try engine.database.node.find(nodeID: 1)
            throw GRDB.DatabaseError(resultCode: .SQLITE_FULL, message: "simulated")
        }) { error in
            XCTAssertTrue(error is DatabaseVolumeError, "got \(error)")
        }
    }

    // MARK: - best effort

    /// The shape for work that may fail without failing the build: an ordinary failure
    /// yields nil and nothing else happens; a machine failure still reaches the handler.
    func test_attemptSwallowsOrdinaryFailuresAndReportsMachineOnes() {
        let ordinary: Int? = FatalErrors.attempt { throw NodeError.other(message: "nothing important") }
        XCTAssertNil(ordinary)
        XCTAssertTrue(reported.isEmpty)

        let machine: Int? = FatalErrors.attempt {
            throw DatabaseVolumeError(filePath: nil, underlying: GRDB.DatabaseError(resultCode: .SQLITE_FULL))
        }
        XCTAssertNil(machine)
        XCTAssertEqual(reported.count, 1)

        XCTAssertEqual(FatalErrors.attempt { 42 }, 42)
    }
}
