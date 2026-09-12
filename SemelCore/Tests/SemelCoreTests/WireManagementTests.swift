//
//  WireManagementTests.swift
//  semel_tests
//
//  Wiring is where the graph actually changes shape. Every structural bug found so far
//  has passed through connectWire or deleteWire.
//

@testable import SemelCore
import XCTest
import SemelNodeKit

final class WireManagementTests: SemelCoreTestCase {

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

    // MARK: - Helpers

    private var database: DatabaseLayer { engine.database }

    private func makeConfiguration(role: String) throws -> NodeRecord {
        let spec = try GraphSpecNode.parse("Configuration(role: '\(role)').output")
        let (node, _) = try spec.findOrCreateMatchingNode()
        return node
    }

    @discardableResult
    private func connect(_ source: NodeRecord, to consumer: NodeRecord, name: String) throws -> (ObjectID, ObjectID) {
        let from = try source.requireID()
        let to   = try consumer.requireID()
        try Wire.connectWire(database: database,
                             fromNodeID: from,
                             fromSymbolID: "output".asSymbolID(),
                             toNodeID: to,
                             toSymbolID: "inherit".asSymbolID(),
                             name: name.asSymbolID())
        return (from, to)
    }

    private func wires(into node: NodeRecord) throws -> [Wire] {
        try database.wire.select(goingToNodeID: try node.requireID(),
                                 toSymbolID: "inherit".asSymbolID())
    }

    private func isPendingDeletion(_ node: NodeRecord) throws -> Bool {
        try XCTUnwrap(database.node.select(nodeID: try node.requireID())).pendingDeletion
    }

    // MARK: - connectWire

    func test_connectingCreatesTheWire() throws {
        let source = try makeConfiguration(role: "source")
        let consumer = try makeConfiguration(role: "consumer")

        try connect(source, to: consumer, name: "link")

        XCTAssertEqual(try wires(into: consumer).count, 1)
    }

    func test_connectingTheSameWireTwiceIsANoOp() throws {
        let source = try makeConfiguration(role: "source")
        let consumer = try makeConfiguration(role: "consumer")

        try connect(source, to: consumer, name: "link")
        try connect(source, to: consumer, name: "link")

        XCTAssertEqual(try wires(into: consumer).count, 1, "the same wire must not be duplicated")
    }

    // Wire names are unique per input port, because the name is how a node addresses
    // one of several wires arriving on the same port.
    func test_twoSourcesCannotShareAWireNameOnOnePort() throws {
        let first = try makeConfiguration(role: "first")
        let second = try makeConfiguration(role: "second")
        let consumer = try makeConfiguration(role: "consumer")

        try connect(first, to: consumer, name: "shared")

        XCTAssertThrowsError(try connect(second, to: consumer, name: "shared")) { error in
            guard case WireError.attemptToCreateWireWithDuplicateName(let name) = error else {
                return XCTFail("expected a duplicate-name error, got \(error)")
            }
            XCTAssertEqual(name, "shared")
        }
    }

    func test_aCycleIsRefused() throws {
        let a = try makeConfiguration(role: "a")
        let b = try makeConfiguration(role: "b")

        try connect(a, to: b, name: "forward")

        XCTAssertThrowsError(try connect(b, to: a, name: "backward")) { error in
            guard case WireError.circularReference = error else {
                return XCTFail("expected a circular reference error, got \(error)")
            }
        }
    }

    func test_aLongerCycleIsAlsoRefused() throws {
        let a = try makeConfiguration(role: "a")
        let b = try makeConfiguration(role: "b")
        let c = try makeConfiguration(role: "c")

        try connect(a, to: b, name: "ab")
        try connect(b, to: c, name: "bc")

        XCTAssertThrowsError(try connect(c, to: a, name: "ca"),
                             "a → b → c → a is still a cycle")
    }

    /// `reset()` relies on this: it deliberately leaves pending-deletion marks alone,
    /// because rewiring a node is what legitimately rescues it.
    func test_connectingRescuesASourceMarkedForDeletion() throws {
        let source = try makeConfiguration(role: "source")
        let consumer = try makeConfiguration(role: "consumer")
        try database.node.updatePendingDeletion(nodeID: try source.requireID(), pendingDeletion: true)

        try connect(source, to: consumer, name: "link")

        XCTAssertFalse(try isPendingDeletion(source),
                       "a node that just gained a consumer must not stay marked for deletion")
    }

    func test_connectingSchedulesTheConsumer() throws {
        let source = try makeConfiguration(role: "source")
        let consumer = try makeConfiguration(role: "consumer")
        try consumer.setScheduled(false)

        try connect(source, to: consumer, name: "link")

        let after = try XCTUnwrap(database.node.select(nodeID: try consumer.requireID()))
        XCTAssertTrue(after.scheduled, "a node whose inputs changed has to reprocess")
    }

    // MARK: - deleteWire

    func test_deletingRemovesTheWire() throws {
        let source = try makeConfiguration(role: "source")
        let consumer = try makeConfiguration(role: "consumer")
        try connect(source, to: consumer, name: "link")

        let wire = try XCTUnwrap(wires(into: consumer).first)
        try wire.deleteWire(database: database)

        XCTAssertTrue(try wires(into: consumer).isEmpty)
    }

    func test_deletingTheLastConsumerMarksTheSourceForDeletion() throws {
        let source = try makeConfiguration(role: "source")
        let consumer = try makeConfiguration(role: "consumer")
        try connect(source, to: consumer, name: "link")

        let wire = try XCTUnwrap(wires(into: consumer).first)
        try wire.deleteWire(database: database)

        XCTAssertTrue(try isPendingDeletion(source),
                      "a source with no consumers left is garbage")
    }

    func test_deletingOneOfSeveralConsumersLeavesTheSourceAlone() throws {
        let source = try makeConfiguration(role: "source")
        let first = try makeConfiguration(role: "first")
        let second = try makeConfiguration(role: "second")
        try connect(source, to: first, name: "link")
        try connect(source, to: second, name: "link")

        let wire = try XCTUnwrap(wires(into: first).first)
        try wire.deleteWire(database: database)

        XCTAssertFalse(try isPendingDeletion(source),
                       "the source still feeds another node")
        let secondAfter = try XCTUnwrap(database.node.select(nodeID: try second.requireID()))
        XCTAssertNotNil(secondAfter)
    }

    func test_deletingAWireThatIsNotThereFails() throws {
        let source = try makeConfiguration(role: "source")
        let consumer = try makeConfiguration(role: "consumer")
        try connect(source, to: consumer, name: "link")

        let wire = try XCTUnwrap(wires(into: consumer).first)
        try wire.deleteWire(database: database)

        XCTAssertThrowsError(try wire.deleteWire(database: database)) { error in
            guard case WireError.failedToDeleteWire = error else {
                return XCTFail("expected failedToDeleteWire, got \(error)")
            }
        }
    }
}
