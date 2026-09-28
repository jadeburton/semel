//
//  InputPortReadScaleTests.swift
//  SemelCore
//

@testable import SemelCore
import Foundation
import GRDB
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-124. A node reads every input port on every evaluation, and an input port takes a
/// fan of wires as wide as the graph demands. Read as the wires and then a select per
/// wire, one evaluation cost the width of the fan in round trips through the serialised
/// database; the project finder, wired to the manifest of every folder of a tree, paid
/// some seventeen hundred per evaluation, and a cold build of a large app spent most of
/// its time in that. Read as one query — the wires joined with the ports they come from —
/// it costs one, whatever the width.
///
/// Asserted in selects issued rather than in seconds, as `WireFanInScaleTests` asserts a
/// wiring in rows read: a count separates one query from one per wire by the width of the
/// fan, where a stopwatch has to be given a band wide enough to survive a loaded machine.
final class InputPortReadScaleTests: SemelCoreTestCase {

    /// The two fan widths. Quadrupled, so a read that selects per wire shows up as four
    /// times the selects while one query stays at one.
    private static let widths = (small: 100, large: 400)

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

    func test_readingAPortIssuesOneSelectHoweverWideItsFanIs() throws {
        let small = try readFanOf(Self.widths.small)
        let large = try readFanOf(Self.widths.large)

        XCTAssertEqual(small.portSelects, 1, small.described)
        XCTAssertEqual(large.portSelects, 1, large.described)
        XCTAssertEqual(small.wireRowsRead, Self.widths.small, "the wire rows the read returns are counted")
        XCTAssertEqual(large.wireRowsRead, Self.widths.large, "the wire rows the read returns are counted")
    }

    // MARK: - What the one query answers

    /// Every wire's value, under the wire's name, from the port the wire comes from.
    func test_theReadHandsBackEveryWiresValueUnderItsName() throws {
        let fan = try readFanOf(Self.widths.small)

        XCTAssertEqual(fan.values.count, Self.widths.small)
        for (index, expected) in fan.sourceHashes.enumerated() {
            guard case .value(let found)? = fan.values["wire\(index)"] else {
                XCTFail("wire\(index) carries no value: \(String(describing: fan.values["wire\(index)"]))")
                continue
            }
            XCTAssertEqual(found, expected, "wire\(index)")
        }
    }

    /// A wire from a port its source has never written is left out, as the select per
    /// wire left it out: the join finds no row and the read says nothing for that name,
    /// rather than inventing a state for it.
    func test_aWireFromAPortWithNoRowIsLeftOut() throws {
        let fan = try readFanOf(3)
        XCTAssertEqual(fan.values.count, 3)

        let orphan = try XCTUnwrap(database.wire.select(goingToNodeID: try fan.consumer.requireID(),
                                                        toSymbolID: "input".asSymbolID(),
                                                        name: "wire1".asSymbolID()).first)
        XCTAssertTrue(try database.outputPort.delete(nodeID: orphan.fromNodeID, nameSymbolID: orphan.fromSymbolID))

        let values = try fan.consumer.readFromInputPort("input")
        XCTAssertEqual(Set(values.keys), ["wire0", "wire2"])
    }

    // MARK: - The plan

    /// A count of one select cannot tell a lookup from a scan SQLite performed inside it,
    /// so the plan is read as well: the wires are found through the index on the port
    /// they arrive at, and each source port through its primary key.
    func test_theJoinSearchesBothTablesThroughTheirIndexes() throws {
        let plan = try database.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN
                SELECT w.name AS wireName, p.nodeID, p.nameSymbolID, p.valueKind, p.dataObjectHash
                FROM Wire w
                LEFT JOIN OutputPort p ON p.nodeID = w.fromNodeID AND p.nameSymbolID = w.fromSymbolID
                WHERE w.toNodeID = ? AND w.toSymbolID = ?
                """, arguments: [1, 2])
                .map { $0["detail"] as String? ?? "" }
        }

        XCTAssertEqual(plan.count, 2, "one step per table, got: \(plan)")
        XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN") }, "neither table may be scanned, got: \(plan)")
        XCTAssertTrue(plan.contains { $0.hasPrefix("SEARCH w") && $0.contains("toNodeID=? AND toSymbolID=?") },
                      "the wires have to be found by the port they arrive at, got: \(plan)")
        XCTAssertTrue(plan.contains { $0.hasPrefix("SEARCH p") && $0.contains("nodeID=? AND nameSymbolID=?") },
                      "each source port has to be found by its key, got: \(plan)")
    }

    // MARK: - Reading one fan

    /// What reading one fan cost, and what it handed back.
    private struct FanRead {
        let consumer:     NodeRecord
        let wires:        Int
        let sourceHashes: [DataObjectHash]
        let values:       [String: NodeValue]
        let portSelects:  Int
        let wireRowsRead: Int
        let seconds:      TimeInterval

        var described: String {
            "\(wires) wires into one port: \(portSelects) port selects, \(wireRowsRead) wire rows read "
            + "in \(String(format: "%.3f", seconds))s"
        }
    }

    /// Creates the sources with a value each, wires the whole fan into one port of a
    /// consumer, then reads that port. Creating and wiring is set-up and is outside
    /// everything the cost counts.
    private func readFanOf(_ width: Int) throws -> FanRead {
        let consumer = try makeNode(role: "consumer-of-\(width)")
        var sourceHashes: [DataObjectHash] = []
        for index in 0..<width {
            let source = try makeNode(role: "source-\(width)-\(index)")
            let hash   = try "content of source \(width)-\(index)".intern()
            try source.writeToOutputPort(SampleTool.output, value: .value(hash))
            sourceHashes.append(hash)
            try Wire.connectWire(database: database,
                                 fromNodeID: try source.requireID(),
                                 fromSymbolID: SampleTool.output.asSymbolID(),
                                 toNodeID: try consumer.requireID(),
                                 toSymbolID: "input".asSymbolID(),
                                 name: "wire\(index)".asSymbolID())
        }

        OutputPortDataAccess.selectCount = 0
        WireDataAccess.rowsRead = 0
        let start  = Date.now
        let values = try consumer.readFromInputPort("input")

        return FanRead(consumer: consumer,
                       wires: width,
                       sourceHashes: sourceHashes,
                       values: values,
                       portSelects: OutputPortDataAccess.selectCount,
                       wireRowsRead: WireDataAccess.rowsRead,
                       seconds: Date.now.timeIntervalSince(start))
    }

    /// A node whose `input` is dynamic, the kind of port the project finder's fan arrives at.
    private func makeNode(role: String) throws -> NodeRecord {
        let (node, _) = try GraphSpecNode(SampleTool.self, properties: ["role": role]).findOrCreateMatchingNode()
        return node
    }
}
