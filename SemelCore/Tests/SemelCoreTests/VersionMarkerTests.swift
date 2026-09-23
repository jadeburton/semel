//
//  VersionMarkerTests.swift
//  SemelCore
//

@testable import SemelCore
import GRDB
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-29. A cache key can prevent a wrong reuse; it cannot cause a recomputation. Nodes are
/// scheduled only on creation, on a wire change, on `nudge()` or after `reset` — so a new
/// Semel that computes different outputs from the same inputs would leave the old
/// artifacts published indefinitely. The engine therefore records the Semel version it
/// built the graph with and resets on mismatch. A schema change cannot be reset past —
/// the preserved input nodes live in the old tables — so that one stops the launch.
final class VersionMarkerTests: SemelCoreTestCase {

    private func makeEngine(_ database: DatabaseLayer) throws -> BuildEngine {
        let engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        return engine
    }

    private func makeDerivedNode() throws -> ObjectID {
        let (node, _) = try GraphSpecNode.parse("Configuration(role: 'doomed').output").findOrCreateMatchingNode()
        return try node.requireID()
    }

    private func storedVersion(_ engine: BuildEngine) throws -> String? {
        try engine.database.metadata.select(key: BuildEngine.semelVersionKey)
    }

    // MARK: - Semel version

    func test_aFreshDatabaseIsStampedWithTheCurrentVersion() throws {
        let engine = try makeEngine(try DatabaseLayer())
        XCTAssertNil(try storedVersion(engine), "precondition: construction alone stamps nothing")

        try engine.reconcileVersionMarkers()

        XCTAssertEqual(try storedVersion(engine), Semel.version)
    }

    func test_theSameVersionLeavesTheGraphAlone() throws {
        let engine  = try makeEngine(try DatabaseLayer())
        try engine.reconcileVersionMarkers()   // the first launch stamps the database
        let derived = try makeDerivedNode()

        try engine.reconcileVersionMarkers()   // a later launch of the same version

        XCTAssertNotNil(try engine.database.node.select(nodeID: derived),
                        "no version change, so nothing may be rebuilt")
    }

    func test_aDifferentVersionResetsTheGraphAndRestamps() throws {
        let engine  = try makeEngine(try DatabaseLayer())
        let derived = try makeDerivedNode()
        try engine.database.metadata.upsert(key: BuildEngine.semelVersionKey, value: "0.0-older")
        try engine.projectFinder.setScheduled(false)

        try engine.reconcileVersionMarkers()

        XCTAssertThrowsError(try engine.database.node.select(nodeID: derived),
                             "a graph built by another Semel must be rebuilt")
        let projectFinder = try XCTUnwrap(engine.database.node.select(nodeID: try engine.projectFinder.requireID()))
        XCTAssertTrue(projectFinder.scheduled, "the rebuild starts from ProjectFinder")
        XCTAssertEqual(try storedVersion(engine), Semel.version)
    }

    /// A database from before the marker existed has nodes but no version. That is an
    /// upgrade, not a fresh start, and gets the same treatment.
    func test_aPopulatedDatabaseWithoutAMarkerIsTreatedAsAnUpgrade() throws {
        let engine  = try makeEngine(try DatabaseLayer())
        let derived = try makeDerivedNode()
        try engine.database.metadata.delete(key: BuildEngine.semelVersionKey)

        try engine.reconcileVersionMarkers()

        XCTAssertThrowsError(try engine.database.node.select(nodeID: derived),
                             "a pre-marker graph must be rebuilt too")
        XCTAssertEqual(try storedVersion(engine), Semel.version)
    }

    /// A port's reason is stored as a number, and `0.1.2` wrote a node that had not run as an
    /// error carrying the word `initializing` where `0.1.3` writes a state of its own. A graph
    /// stamped with the older version is rebuilt rather than read against this version's
    /// meaning, so no port keeps a reason nothing writes.
    func test_aGraphFromBeforeTheReasonsWereStatesIsRebuilt() throws {
        let engine  = try makeEngine(try DatabaseLayer())
        let derived = try makeDerivedNode()
        try engine.database.node.select(nodeID: derived).writeToOutputPort(
            "output", value: .noValue(reason: .error(messageDataObjectHash: try "initializing".intern())))
        try engine.database.metadata.upsert(key: BuildEngine.semelVersionKey, value: "0.1.2")

        try engine.reconcileVersionMarkers()

        XCTAssertThrowsError(try engine.database.node.select(nodeID: derived),
                             "a graph whose port reasons mean something else must be rebuilt")
        XCTAssertEqual(try storedVersion(engine), Semel.version)
    }

    func test_theInputFileSystemSurvivesAVersionChange() throws {
        let engine = try makeEngine(try DatabaseLayer())
        let source = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("src"), pinned: true)
        try engine.database.metadata.upsert(key: BuildEngine.semelVersionKey, value: "0.0-older")

        try engine.reconcileVersionMarkers()

        XCTAssertNotNil(try engine.database.node.select(nodeID: try source.requireID()),
                        "a version change rebuilds what is derived, never what was pushed")
    }

    // MARK: - Schema

    private func makeTemporaryDatabasePath() throws -> String {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("graph.sqlite").path
    }

    /// The fingerprint of a database that has been used must still equal the one a fresh
    /// database gets — SQLite adds its own `sqlite_sequence` table on the first insert into
    /// an AUTOINCREMENT table, and that must not read as a schema change.
    func test_aUsedDatabaseStillMatchesTheExpectedSchema() throws {
        let database = try DatabaseLayer(filePath: try makeTemporaryDatabasePath())
        _ = try database.symbol.insert(name: "anything")

        XCTAssertEqual(try database.schemaFingerprint(), try DatabaseLayer.expectedSchemaFingerprint())
    }

    /// A wire's name is part of its key, so a database keyed without it cannot hold two
    /// wires between one pair of ports and cannot be migrated into one that can. Recreating
    /// that table, indexes and all, is the closest a test comes to opening such a file: only
    /// the key differs, and that alone has to stop the launch.
    func test_aDatabaseWithTheOlderWireKeyIsRefused() throws {
        let path     = try makeTemporaryDatabasePath()
        let database = try DatabaseLayer(filePath: path)
        let (wireTable, wireIndexes) = try database.dbQueue.read { db in
            (try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'Wire'"),
             try String.fetchAll(db, sql: """
                SELECT sql FROM sqlite_master
                WHERE type = 'index' AND tbl_name = 'Wire' AND sql IS NOT NULL
                """))
        }
        // The older statement is this one without the name in its key — the text an older
        // file holds, so nothing but the key can be what the check reacts to.
        let olderWireTable = try XCTUnwrap(wireTable).replacingOccurrences(of: ", \"name\"))", with: "))")
        XCTAssertNotEqual(olderWireTable, wireTable, "precondition: the name is part of the key")

        try database.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE Wire")
            try db.execute(sql: olderWireTable)
            for indexStatement in wireIndexes {
                try db.execute(sql: indexStatement)
            }
        }

        let engine = try makeEngine(database)

        XCTAssertThrowsError(try engine.reconcileVersionMarkers()) { error in
            guard let schemaError = error as? DatabaseSchemaChangedError else {
                return XCTFail("expected DatabaseSchemaChangedError, got \(error)")
            }
            XCTAssertTrue(schemaError.unrecoverableDescription.contains(path),
                          "the user has to know which file to delete, got: \(schemaError.unrecoverableDescription)")
        }
    }

    func test_aChangedSchemaStopsTheLaunchAndNamesTheFile() throws {
        let path     = try makeTemporaryDatabasePath()
        let database = try DatabaseLayer(filePath: path)
        try database.dbQueue.write { db in
            try db.execute(sql: "ALTER TABLE Symbol ADD COLUMN extra TEXT")
        }

        let engine = try makeEngine(database)

        XCTAssertThrowsError(try engine.reconcileVersionMarkers()) { error in
            guard let schemaError = error as? DatabaseSchemaChangedError else {
                return XCTFail("expected DatabaseSchemaChangedError, got \(error)")
            }
            XCTAssertTrue(schemaError.unrecoverableDescription.contains(path),
                          "the user has to know which file to delete, got: \(schemaError.unrecoverableDescription)")
        }
    }
}
