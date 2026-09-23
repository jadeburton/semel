//
//  DatabaseFailureClassificationTests.swift
//  SemelCore
//

@testable import SemelCore
import GRDB
import SemelDatabaseModels
import XCTest

/// B-45. GRDB reports every failure as one `DatabaseError` type, mixing "the disk is full"
/// with "the file is locked right now" and "this INSERT violates a constraint". The first
/// is a property of the machine and stops the build; the others belong to the caller.
/// Conformance to `UnrecoverableError` is per type, so the translation happens where every
/// GRDB error is born — the database layer's read, write and transaction boundary — and
/// produces one narrow type for the machine's failures only.
final class DatabaseFailureClassificationTests: SemelCoreTestCase {

    private var reported: [any UnrecoverableError] = []
    private var database: DatabaseLayer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        reported = []
        FatalErrors.handler = { [weak self] error in self?.reported.append(error) }
        database = try DatabaseLayer()
    }

    override func tearDown() {
        FatalErrors.handler = FatalErrors.defaultHandler
        database = nil
        super.tearDown()
    }

    private func failure(_ code: ResultCode) -> GRDB.DatabaseError {
        GRDB.DatabaseError(resultCode: code, message: "simulated")
    }

    /// The volume is out of room or out of reach, or the file is no longer a database.
    private let machineFailures: [ResultCode] = [
        .SQLITE_FULL, .SQLITE_IOERR, .SQLITE_IOERR_WRITE, .SQLITE_CANTOPEN, .SQLITE_READONLY,
        .SQLITE_PERM, .SQLITE_NOMEM, .SQLITE_CORRUPT, .SQLITE_NOTADB,
    ]

    /// Transient, or a bug in the statement — the build carries on and reports them.
    private let ordinaryFailures: [ResultCode] = [
        .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_INTERRUPT, .SQLITE_CONSTRAINT, .SQLITE_ERROR, .SQLITE_MISUSE,
    ]

    func test_aMachineFailureInAWriteIsUnrecoverable() {
        for code in machineFailures {
            XCTAssertThrowsError(try database.write { _ in throw failure(code) }, "\(code)") { error in
                XCTAssertTrue(error is DatabaseVolumeError, "\(code) should be translated, got \(error)")
            }
        }
    }

    func test_aMachineFailureInAReadOrATransactionIsUnrecoverableToo() {
        XCTAssertThrowsError(try database.read { _ in throw failure(.SQLITE_IOERR) }) { error in
            XCTAssertTrue(error is DatabaseVolumeError, "got \(error)")
        }
        XCTAssertThrowsError(try database.withTransaction { throw failure(.SQLITE_FULL) }) { error in
            XCTAssertTrue(error is DatabaseVolumeError, "got \(error)")
        }
        // A nested call inside a transaction reaches the outer boundary; it must not be
        // wrapped twice, and it must still come out translated.
        XCTAssertThrowsError(try database.withTransaction {
            try database.write { _ in throw failure(.SQLITE_FULL) }
        }) { error in
            XCTAssertTrue(error is DatabaseVolumeError, "got \(error)")
        }
    }

    func test_anOrdinaryFailureComesThroughUntouched() {
        for code in ordinaryFailures {
            XCTAssertThrowsError(try database.write { _ in throw failure(code) }, "\(code)") { error in
                XCTAssertFalse(error is any UnrecoverableError, "\(code) is not the machine's fault, got \(error)")
                XCTAssertTrue(error is GRDB.DatabaseError, "\(code) should reach the caller as GRDB threw it, got \(error)")
            }
        }
    }

    /// Errors that are not GRDB's at all — the layer's own `nodeNotFound`, say — pass through.
    func test_theLayersOwnErrorsPassThrough() {
        XCTAssertThrowsError(try database.write { _ in throw DatabaseLayer.DatabaseError.nodeNotFound }) { error in
            XCTAssertFalse(error is any UnrecoverableError, "got \(error)")
        }
    }

    func test_theTranslatedErrorReachesTheFatalHandler() {
        do {
            try database.write { _ in throw failure(.SQLITE_FULL) }
        } catch {
            FatalErrors.check(error)
        }

        XCTAssertEqual(reported.count, 1)
    }

    func test_theMessageNamesTheFileAndWhatToCheck() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("graph.sqlite").path
        let fileDatabase = try DatabaseLayer(filePath: path)

        XCTAssertThrowsError(try fileDatabase.write { _ in throw failure(.SQLITE_FULL) }) { error in
            guard let volume = error as? DatabaseVolumeError else { return XCTFail("got \(error)") }
            let message = volume.unrecoverableDescription
            XCTAssertTrue(message.contains(path), "should name the file: \(message)")
            XCTAssertTrue(message.contains("free space"), "should say what to check: \(message)")
            XCTAssertTrue(message.contains("disk is full"), "should carry SQLite's reason: \(message)")
        }

        XCTAssertThrowsError(try fileDatabase.write { _ in throw failure(.SQLITE_CORRUPT) }) { error in
            guard let volume = error as? DatabaseVolumeError else { return XCTFail("got \(error)") }
            let message = volume.unrecoverableDescription
            // A damaged file cannot be repaired from inside the build, and it is also the
            // only record of how it came to be damaged — the same answer `reset` and the
            // schema gate give: move it aside, siblings included.
            XCTAssertTrue(message.contains("Move the file aside"), message)
            XCTAssertFalse(message.lowercased().contains("delete"), message)
            XCTAssertTrue(message.contains("-wal") && message.contains("-shm"), message)
        }
    }
}
