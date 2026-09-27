//
//  WireFanInScaleTests.swift
//  SemelCore
//

@testable import SemelCore
import Foundation
import GRDB
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-106. An input port takes a fan of wires as wide as the graph demands — one per source,
/// each under a name of the consumer's choosing — and `connectWire` guards every new wire
/// against the names already arriving there. Asked by reading the wires at the port and
/// scanning them, that guard costs the whole fan per connection, so wiring a fan of N costs
/// O(N²) row reads. Asked as a lookup by `(toNodeID, toSymbolID, name)`, it costs one.
///
/// The cost is asserted in rows read rather than in seconds, the way
/// `FolderRemovalScaleTests` asserts a removal in manifest rebuilds: a count separates a
/// lookup from a scan by the width of the fan, where a stopwatch has to be given a band
/// wide enough to survive a loaded machine. The seconds are carried for a failure message
/// to quote, and are never asserted on.
final class WireFanInScaleTests: SemelCoreTestCase {

    /// The two fan widths. Quadrupled, so a guard that reads the fan it is guarding shows up
    /// as sixteen times the rows while a lookup stays at the same handful per wire.
    private static let widths = (small: 100, large: 400)

    /// Wire rows one connection may read, whatever the fan already at the port. The wire
    /// asked for, the name it must not collide with, and the target's outgoing wires that
    /// the cycle check walks are each a lookup answering nothing or one row; the allowance
    /// is a few times that, and orders below the fan itself.
    private static let rowsPerConnection = 4

    private var engine: BuildEngine!

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

    private var database: DatabaseLayer { engine.database }

    // MARK: - Growth

    func test_wiringAFanIntoOnePortReadsTheSameRowsPerWireHoweverWideItIs() throws {
        let small = try fanOf(Self.widths.small)
        let large = try fanOf(Self.widths.large)

        XCTAssertLessThanOrEqual(small.rowsRead, small.wires * Self.rowsPerConnection, small.described)
        XCTAssertLessThanOrEqual(large.rowsRead, large.wires * Self.rowsPerConnection, large.described)
        XCTAssertLessThanOrEqual(large.rowsReadPerWire, small.rowsReadPerWire + 1,
                                 "the reads a connection costs must not follow the fan — "
                                 + "\(small.described), \(large.described)")
    }

    // MARK: - The lookup the guard is asked as

    /// A count alone cannot tell a lookup from a scan SQLite performed and handed one row
    /// back from, so the plan is read as well: the three columns the guard asks about have
    /// to be searched through an index, not scanned for.
    func test_theNameGuardIsAnIndexedLookup() throws {
        let plan = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT * FROM "Wire" WHERE "toNodeID" = ? AND "toSymbolID" = ? AND "name" = ?
                """, arguments: [1, 2, 3])
                .map { $0["detail"] as String? ?? "" }
                .joined(separator: "\n")
        }

        XCTAssertTrue(plan.contains("SEARCH"), "the guard must not scan the table, got: \(plan)")
        XCTAssertTrue(plan.contains("toNodeID=? AND toSymbolID=? AND name=?"),
                      "all three columns have to be the index's, got: \(plan)")
    }

    // MARK: - What the guard still refuses

    /// The lookup replaces a scan, not the rule: a name already arriving at the port from
    /// another source is still refused, wherever in the fan it sits.
    func test_aNameTakenEarlyInTheFanIsStillRefusedAtTheEndOfIt() throws {
        let fan = try fanOf(Self.widths.small)
        let latecomer = try makeNode(role: "latecomer")

        XCTAssertThrowsError(try connect(latecomer, to: fan.consumer, name: "wire0")) { error in
            guard case WireError.attemptToCreateWireWithDuplicateName(let name) = error else {
                return XCTFail("expected a duplicate-name error, got \(error)")
            }
            XCTAssertEqual(name, "wire0")
        }
    }

    /// And the fan itself is the fan that was asked for: one wire per source, none dropped
    /// by a guard that found itself in the rows it was reading.
    func test_everyWireOfTheFanIsThere() throws {
        let fan = try fanOf(Self.widths.small)

        let wires = try database.wire.select(goingToNodeID: try fan.consumer.requireID(),
                                             toSymbolID: "input".asSymbolID())
        XCTAssertEqual(wires.count, Self.widths.small)
        XCTAssertEqual(Set(wires.map { $0.fromNodeID }).count, Self.widths.small,
                       "each wire comes from a source of its own")
    }

    // MARK: - Wiring one fan

    /// What wiring one fan cost: the wire rows read doing it, and the seconds it took, which
    /// are carried for a failure message to quote and are never asserted on.
    private struct FanCost {
        let consumer: NodeRecord
        let wires:    Int
        let rowsRead: Int
        let seconds:  TimeInterval

        var rowsReadPerWire: Int { rowsRead / wires }

        var described: String {
            "\(wires) wires into one port: \(rowsRead) wire rows read "
            + "(\(rowsReadPerWire) per wire) in \(String(format: "%.3f", seconds))s"
        }
    }

    /// Creates the sources and their consumer, then wires the whole fan into one port of it.
    /// Creating the nodes is set-up and is outside everything the cost counts.
    private func fanOf(_ width: Int) throws -> FanCost {
        let consumer = try makeNode(role: "consumer-of-\(width)")
        let sources  = try (0..<width).map { try makeNode(role: "source-\(width)-\($0)") }

        WireDataAccess.rowsRead = 0
        let start = Date.now
        for (index, source) in sources.enumerated() {
            try connect(source, to: consumer, name: "wire\(index)")
        }

        return FanCost(consumer: consumer,
                       wires: width,
                       rowsRead: WireDataAccess.rowsRead,
                       seconds: Date.now.timeIntervalSince(start))
    }

    private func makeNode(role: String) throws -> NodeRecord {
        let spec = try GraphSpecNode.parse("TreeMerger(under: '\(role)').files")
        let (node, _) = try spec.findOrCreateMatchingNode()
        return node
    }

    private func connect(_ source: NodeRecord, to consumer: NodeRecord, name: String) throws {
        try Wire.connectWire(database: database,
                             fromNodeID: try source.requireID(),
                             fromSymbolID: "files".asSymbolID(),
                             toNodeID: try consumer.requireID(),
                             toSymbolID: "input".asSymbolID(),
                             name: name.asSymbolID())
    }
}
