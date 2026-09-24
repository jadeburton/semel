//
//  DatabaseLayerSnapshotTests.swift
//  SemelCoreTests
//
//  `withReadSnapshot`: the reader's twin of `withTransaction`.
//
//  It exists because two `selectAll`s are not one state. `GraphCheck` reads the nodes and
//  then the wires, and a node created between the two makes a healthy wire look like it
//  points at nothing — a false finding in a command the end-to-end harness runs after
//  every build. Tested here rather than in the check, because what is being asserted is a
//  property of the database layer.
//
//  `SemelDatabaseModels` has no test target of its own, so its tests live in this one.
//

@testable import SemelCore
import GRDB
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class DatabaseLayerSnapshotTests: SemelCoreTestCase {

    private var database: DatabaseLayer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try DatabaseLayer()
    }

    override func tearDown() {
        database = nil
        super.tearDown()
    }

    // MARK: - One state for the whole block

    /// What makes the block a snapshot is that `DatabaseQueue` is serial: the reader holds
    /// the queue, so a writer cannot land inside it.
    ///
    /// Connection identity would prove nothing — a `DatabaseQueue` has exactly one
    /// connection, so every read shares it whether or not there is a snapshot. So this
    /// releases a writer on another thread *from inside* the block, waits until that
    /// thread is at the write call, and asserts the two reads agree. The last assertion is
    /// what keeps it from passing vacuously: it proves the writer really did run, and was
    /// held off only until the block ended.
    func test_aReadSnapshotHoldsOffAWriterForItsWholeBlock() throws {
        let startWriter     = DispatchSemaphore(value: 0)
        let writerAtTheDoor = DispatchSemaphore(value: 0)
        let writerDone      = DispatchSemaphore(value: 0)

        DispatchQueue.global().async { [database] in
            startWriter.wait()
            writerAtTheDoor.signal()
            _ = try? database?.node.insert(NodeRecord(kind: Configuration.kind))
            writerDone.signal()
        }

        var counts: [Int] = []
        try database.withReadSnapshot {
            counts.append(try database.node.select(kind: Configuration.kind).count)
            startWriter.signal()
            writerAtTheDoor.wait()
            counts.append(try database.node.select(kind: Configuration.kind).count)
        }

        XCTAssertEqual(writerDone.wait(timeout: .now() + 5), .success, "the writer must get its turn")
        XCTAssertEqual(counts.first, counts.last, "a writer cannot land between two reads of one snapshot")
        XCTAssertEqual(try database.node.select(kind: Configuration.kind).count, (counts.first ?? 0) + 1,
                       "and it lands as soon as the snapshot ends")
    }

    /// The inner call finds a connection already published and participates in it, which
    /// is what makes every accessor inside a snapshot share its one state.
    func test_aSnapshotNestedInASnapshotIsTheSameSnapshot() throws {
        _ = try database.node.insert(NodeRecord(kind: Configuration.kind))

        var inner = 0
        try database.withReadSnapshot {
            try database.withReadSnapshot {
                inner = try database.node.select(kind: Configuration.kind).count
            }
        }

        XCTAssertEqual(inner, 1)
    }

    // MARK: - A write from inside

    /// SQLite refuses it with `SQLITE_READONLY`, which is also what a read-only *volume*
    /// gives — and the layer's boundary would otherwise translate that into the
    /// unrecoverable error that stops the process and blames the reader's disk. Inside a
    /// snapshot that diagnosis is wrong twice over, so the code is re-read as the caller's
    /// bug and the process lives to report it.
    func test_aWriteInsideASnapshotIsNamedAsTheCallersBugNotTheVolumes() throws {
        XCTAssertThrowsError(try database.withReadSnapshot {
            _ = try database.node.insert(NodeRecord(kind: Configuration.kind))
        }) { error in
            XCTAssertTrue(error is WriteInsideReadSnapshotError, "got \(type(of: error)): \(error)")
            XCTAssertFalse(error is DatabaseVolumeError, "the volume is not what is wrong")
            XCTAssertTrue("\(error)".hasPrefix("a write was attempted inside a read snapshot"), "\(error)")
        }
    }

    /// Only a read-only refusal is re-read. Anything else the work throws is the caller's
    /// own error and comes back as it was.
    func test_anyOtherErrorFromInsideASnapshotPassesThrough() throws {
        struct Boom: Error {}

        XCTAssertThrowsError(try database.withReadSnapshot { throw Boom() }) { error in
            XCTAssertTrue(error is Boom, "got \(type(of: error))")
        }
    }
}
