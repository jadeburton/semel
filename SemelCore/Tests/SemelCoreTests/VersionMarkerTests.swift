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

    /// A file the formula names and nobody pushed lives in the input file system, which the
    /// rebuild preserves — port rows and all. Its port holds what another Semel wrote there,
    /// so the rebuild restates it: a preserved file with no value has never had one, and
    /// leaving the old spelling would have it read as a failure with a word for a message.
    func test_aPreservedFilesPortIsRestatedByTheRebuild() throws {
        let engine = try makeEngine(try DatabaseLayer())
        let (file, _) = try GraphSpecNode.parse("StaticFile(path: 'input:/clang.cfg')")
            .findOrCreateMatchingNode()
        try file.writeToOutputPort(
            "output", value: .noValue(reason: .error(messageDataObjectHash: try "initializing".intern())))
        try engine.database.metadata.upsert(key: BuildEngine.semelVersionKey, value: "0.1.2")

        try engine.reconcileVersionMarkers()

        let fileID = try file.requireID()
        XCTAssertNotNil(try engine.database.node.select(nodeID: fileID), "a pushed file survives a rebuild")
        let port = try XCTUnwrap(engine.database.outputPort.select(nodeID: fileID,
                                                                   nameSymbolID: "output".asSymbolID()))
        XCTAssertEqual(port.valueKind, .initializing)
        XCTAssertNil(port.dataObjectHash)
    }

    /// The restating is a migration of one encoding, not a sweep of every error: a file the
    /// user removed while a formula still named it says so, and keeps saying so.
    func test_aPreservedFilesOwnErrorSurvivesTheRebuild() throws {
        let engine = try makeEngine(try DatabaseLayer())
        let (file, _) = try GraphSpecNode.parse("StaticFile(path: 'input:/gone.c')")
            .findOrCreateMatchingNode()
        try file.writeToOutputPort(
            "output", value: .noValue(reason: .error(messageDataObjectHash: try "Deleted".intern())))
        try engine.database.metadata.upsert(key: BuildEngine.semelVersionKey, value: "0.1.2")

        try engine.reconcileVersionMarkers()

        let port = try XCTUnwrap(engine.database.outputPort.select(nodeID: try file.requireID(),
                                                                   nameSymbolID: "output".asSymbolID()))
        XCTAssertEqual(port.valueKind, .error)
        XCTAssertEqual(try port.dataObjectHash?.resolveAsString(), "Deleted")
    }

    /// What was pushed is what a rebuild must never touch: a file with content keeps it, so
    /// the restating above cannot cost a cache hit or a re-push.
    func test_aPushedFilesContentSurvivesTheRebuild() throws {
        let engine = try makeEngine(try DatabaseLayer())
        let (file, _) = try GraphSpecNode.parse("StaticFile(path: 'input:/clang.cfg')")
            .findOrCreateMatchingNode()
        _ = try XCTUnwrap(file.nodeAsAny() as? StaticFile).replaceContent(try "target=arm64".intern())
        try engine.database.metadata.upsert(key: BuildEngine.semelVersionKey, value: "0.1.2")

        try engine.reconcileVersionMarkers()

        let port = try XCTUnwrap(engine.database.outputPort.select(nodeID: try file.requireID(),
                                                                   nameSymbolID: "output".asSymbolID()))
        XCTAssertEqual(port.valueKind, .value)
        XCTAssertEqual(try port.dataObjectHash?.resolveAsString(), "target=arm64")
    }

    /// A plain `reset` keeps the cache, because the key covers the inputs. It says nothing
    /// about which Semel computed the entry, so the rebuild a version change asks for has
    /// to discard the entries too — otherwise it republishes the very artifacts the marker
    /// exists to replace.
    func test_aVersionChangeDiscardsTheCachedBuildsToo() throws {
        let engine = try makeEngine(try DatabaseLayer())
        try engine.database.cacheEntry.insert(.init(hash: "an-entry-built-by-the-older-semel",
                                                    content: [UInt8]("{}".utf8),
                                                    cost: 100,
                                                    timestamp: Date()))
        try engine.database.metadata.upsert(key: BuildEngine.semelVersionKey, value: "0.0-older")

        try engine.reconcileVersionMarkers()

        XCTAssertEqual(try engine.database.cacheEntry.count(), 0,
                       "a new Semel may compute different outputs from the same inputs")
    }

    /// Nobody typed this reset, so nobody is watching a reply for the copy it leaves in the
    /// home. It is said on the server's own channel instead — `Debug.log` is compiled out of
    /// a release build, which would leave the file there unexplained.
    func test_aVersionChangeSaysWhereTheGraphItDiscardedWent() throws {
        let path   = try makeTemporaryDatabasePath()
        let engine = try makeEngine(try DatabaseLayer(filePath: path))
        let saidLines = LineRecorder()
        engine.noticeReporter = { line in saidLines.record(line) }
        _ = try makeDerivedNode()
        try engine.database.metadata.upsert(key: BuildEngine.semelVersionKey, value: "0.0-older")

        try engine.reconcileVersionMarkers()

        let line = try XCTUnwrap(saidLines.lines.first, "the copy has to be announced")
        XCTAssertTrue(line.contains(path + ".broken-"), "it names the copy, got: \(line)")
        XCTAssertTrue(line.contains("yours to delete"), "it says whose the file is, got: \(line)")
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
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
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

    /// The graph a reset discards is copied aside rather than dropped, and the file this
    /// gate stops on is the same evidence. What it asks the user to do has to agree.
    func test_aChangedSchemaAsksForTheFileToBeMovedAsideRatherThanDeleted() {
        let error = DatabaseSchemaChangedError(filePath: "/tmp/semel-home/graph.sqlite")

        XCTAssertTrue(error.unrecoverableDescription.contains("Move that file aside"),
                      error.unrecoverableDescription)
        XCTAssertFalse(error.unrecoverableDescription.lowercased().contains("delete"),
                       "deleting the file destroys the only record of the broken graph")
        // Committed rows live in the write-ahead log until a checkpoint, so a move that
        // leaves the siblings behind loses the newest evidence and hands a stale log to
        // the database SQLite creates next at the same path.
        XCTAssertTrue(error.unrecoverableDescription.contains("-wal"),
                      "the siblings move with it: \(error.unrecoverableDescription)")
        XCTAssertTrue(error.unrecoverableDescription.contains("-shm"),
                      error.unrecoverableDescription)
    }
}

/// Collects what was said on a channel a test swapped out, as a reference so the closure
/// that records has something to write into.
final class LineRecorder {
    private(set) var lines: [String] = []
    func record(_ line: String) { lines.append(line) }
}
