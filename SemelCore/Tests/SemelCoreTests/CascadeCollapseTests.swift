//
//  CascadeCollapseTests.swift
//  SemelCoreTests
//
//  B-74. One failing header stops every node that reads it, and every node that reads
//  those, so a single cause reaches the reader as hundreds of identical lines that say
//  only "an input is in error". The report folds that cascade back onto the node that
//  caused it: the cause once, and a count of what carries it.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class CascadeCollapseTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var captured: [[ErrorReport.Entry]] = []
    private var database: DatabaseLayer { engine.database }

    /// The sentence a node carries when its only problem is that something upstream failed.
    private let carried = "\(NodeError.inputValueInError)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.errorReporter = { [weak self] entries in self?.captured.append(entries) }
    }

    override func tearDown() {
        engine = nil
        captured = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeFile(path: String) throws -> ObjectID {
        try NodeRecord.createNode(database: database, kind: StaticFile.kind,
                                  properties: ["path": path], graphSpec: nil).requireID()
    }

    /// A node with no path of its own, so the label says only its type — what a compiler
    /// node in the middle of a cascade looks like in a report.
    private func makeConsumer(tag: String) throws -> ObjectID {
        try NodeRecord.createNode(database: database, kind: TreeMerger.kind,
                                  properties: ["tag": tag], graphSpec: nil).requireID()
    }

    /// Wiring a node writes pending to every output of its target, so the errors are put on
    /// last — a graph is wired before it fails, too.
    private func fail(_ nodeID: ObjectID, with message: String) throws {
        try database.node.select(nodeID: nodeID)
            .writeToOutputPort("output",
                               value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
    }

    private func connect(_ from: ObjectID, to: ObjectID, name: String) throws {
        try Wire.connectWire(database: database,
                             fromNodeID: from,
                             fromSymbolID: "output".asSymbolID(),
                             toNodeID: to,
                             toSymbolID: "input".asSymbolID(),
                             name: name.asSymbolID())
    }

    /// One header every consumer reads, each consumer feeding one shared sink: the shape a
    /// deleted header leaves behind, in miniature. Every node downstream of the header
    /// carries the cascade, so the graph holds `consumers + 2` failing nodes and one cause.
    @discardableResult
    private func makeCascade(consumers: Int) throws -> ObjectID {
        let source = try makeFile(path: "input:/shared.h")
        let sink   = try makeConsumer(tag: "sink")

        var carriers = [sink]
        for index in 0 ..< consumers {
            let consumer = try makeConsumer(tag: "consumer \(index)")
            try connect(source, to: consumer, name: "header")
            try connect(consumer, to: sink, name: "part \(index)")
            carriers.append(consumer)
        }

        try fail(source, with: "the file is gone")
        for carrier in carriers {
            try fail(carrier, with: carried)
        }

        return source
    }

    // MARK: - The report

    /// The failure B-74 describes: one deleted header stops every node that reads it, and an
    /// entry each would be hundreds of lines saying "an input is in error" and naming no fix.
    /// The report names the one node that can be fixed.
    func test_aCascadeIsReportedAsItsCauseAlone() throws {
        try makeCascade(consumers: 20)
        XCTAssertEqual(Set(try database.outputPort.selectAllErrors().map(\.nodeID)).count, 22,
                       "the cause and every node downstream of it are in error")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].map(\.label), ["StaticFile  'input:/shared.h'"])
    }

    /// The nodes that vanish from the report are still counted, so the size of the damage
    /// is on the page even though the list of it is not.
    func test_theCauseSaysHowMuchIsDownstreamOfIt() throws {
        try makeCascade(consumers: 20)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0][0].downstreamCarrierCount, 21,
                       "twenty consumers and the sink they feed")
        XCTAssertEqual(ErrorReport.lines(for: captured[0][0]),
                       ["❌ StaticFile  'input:/shared.h'",
                        "   · output: the file is gone",
                        "   · and 21 nodes downstream carry it",
                        ""])
    }

    func test_oneNodeDownstreamReadsAsOne() throws {
        let source   = try makeFile(path: "input:/shared.h")
        let consumer = try makeConsumer(tag: "only")
        try connect(source, to: consumer, name: "header")
        try fail(source, with: "the file is gone")
        try fail(consumer, with: carried)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(ErrorReport.lines(for: captured[0][0]).filter { $0.contains("·") },
                       ["   · output: the file is gone", "   · and 1 node downstream carries it"])
    }

    /// A node that has something of its own to say is a cause, wherever it sits: its message
    /// names a fix the cause upstream does not.
    func test_aNodeWithAnErrorOfItsOwnIsReportedEvenBelowACause() throws {
        let source   = try makeFile(path: "input:/shared.h")
        let consumer = try makeConsumer(tag: "consumer")
        try connect(source, to: consumer, name: "header")
        try fail(source, with: "the file is gone")
        try fail(consumer, with: "no tool exists at '/usr/bin/nonesuch'")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0].map(\.label), ["StaticFile  'input:/shared.h'", "TreeMerger"])
        XCTAssertEqual(captured[0].map(\.downstreamCarrierCount), [0, 0])
    }

    /// A carrier whose cause is not in the graph has nothing upstream to blame, so the walk
    /// stops at it rather than reporting nothing. A chain is what folds: the topmost carrier
    /// stands in for the cause and the carriers wired below it fold onto it. Siblings of it
    /// would be a cause each — the collector is what keeps that shape from reaching a
    /// report, by taking every consumer of a node before the node itself.
    func test_aCarrierWithNothingFailingUpstreamStandsInForItsOwnCause() throws {
        let head = try makeConsumer(tag: "head")
        let tail = try makeConsumer(tag: "tail")
        try connect(head, to: tail, name: "part")
        try fail(head, with: carried)
        try fail(tail, with: carried)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0].count, 1)
        XCTAssertEqual(captured[0][0].downstreamCarrierCount, 1)
        XCTAssertEqual(captured[0][0].items, [ErrorReport.Item(ports: ["output"], message: carried)])
    }

    /// Two headers deleted at once, one consumer reading both: the consumer is folded, and
    /// both causes say it is downstream of them, because either one is worth fixing.
    func test_aCarrierFedByTwoCausesIsCountedUnderEach() throws {
        let first    = try makeFile(path: "input:/first.h")
        let second   = try makeFile(path: "input:/second.h")
        let consumer = try makeConsumer(tag: "consumer")
        try connect(first, to: consumer, name: "first")
        try connect(second, to: consumer, name: "second")
        try fail(first, with: "the file is gone")
        try fail(second, with: "the file is gone")
        try fail(consumer, with: carried)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0].map(\.label),
                       ["StaticFile  'input:/first.h'", "StaticFile  'input:/second.h'"])
        XCTAssertEqual(captured[0].map(\.downstreamCarrierCount), [1, 1])
    }

    /// The report is the same report on the pass after: a cause already named is not named
    /// again, and neither is the cascade under it.
    func test_aCascadeAlreadyReportedIsNotReportedAgain() throws {
        try makeCascade(consumers: 20)

        engine.reportIdleTimeErrors()
        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
    }

    /// A carrier is reported for nothing while it is folded, so nothing is remembered about
    /// it, and the message it carries still counts as new the day it becomes the cause —
    /// which is what the node upstream of it being collected makes it.
    func test_aFoldedCarrierIsStillReportedWhenItBecomesTheCause() throws {
        let source   = try makeFile(path: "input:/shared.h")
        let consumer = try makeConsumer(tag: "consumer")
        try connect(source, to: consumer, name: "header")
        try fail(source, with: "the file is gone")
        try fail(consumer, with: carried)

        engine.reportIdleTimeErrors()

        // The cause goes the way a collected node goes: its ports with it.
        _ = try database.outputPort.deleteAll(nodeID: source)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[1].map(\.label), ["TreeMerger"])
    }

    // MARK: - The rule

    /// The one sentence that means "someone else failed". A port carries the hash of its
    /// message and nothing else, so this comparison is all the engine has to tell a carrier
    /// from a cause.
    func test_onlyTheInputInErrorSentenceIsCarried() {
        XCTAssertTrue(ErrorReport.isCarriedFromAnInput("\(NodeError.inputValueInError)"))
        XCTAssertFalse(ErrorReport.isCarriedFromAnInput("\(NodeError.inputValuePending)"))
        XCTAssertFalse(ErrorReport.isCarriedFromAnInput("the file is gone"))
        XCTAssertFalse(ErrorReport.isCarriedFromAnInput(ErrorReport.emptyMessage))
    }

    /// A node carrying an input error *and* something of its own is a cause: the something
    /// of its own is what a reader can act on.
    func test_aNodeIsACarrierOnlyWhenEveryMessageIsCarried() throws {
        let source   = try makeFile(path: "input:/shared.h")
        let consumer = try makeConsumer(tag: "consumer")
        try connect(source, to: consumer, name: "header")
        try fail(source, with: "the file is gone")
        try fail(consumer, with: carried)
        try database.node.select(nodeID: consumer)
            .writeToOutputPort("errorLog",
                               value: .noValue(reason: .error(messageDataObjectHash: try "and a log".intern())))

        let byNode = Dictionary(grouping: try database.outputPort.selectAllErrors(), by: \.nodeID)

        XCTAssertEqual(ErrorReport.causes(amongErrorPorts: byNode, database: database),
                       [source: 0, consumer: 0])
    }
}
