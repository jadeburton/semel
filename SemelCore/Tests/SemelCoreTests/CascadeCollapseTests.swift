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

    /// The sentence a report writes for a node whose only problem is that something upstream
    /// failed. The node carries a state, not a message; this is how that state reads.
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

    /// A node made the way the engine makes every node: from its tree, static wires and
    /// all, and found rather than made when the graph already holds it.
    private func make(_ specNode: GraphSpecNode) throws -> ObjectID {
        try specNode.findOrCreateMatchingNode().fromNode.requireID()
    }

    private func makeFile(path: String) throws -> ObjectID {
        try make(.staticFile(at: path))
    }

    /// A node with no path of its own, so the label says only its type — what a compiler
    /// node in the middle of a cascade looks like in a report — reading `inputs` by wire
    /// name. Read at `output`, the port the states below are written to.
    private func consumer(tag: String, reading inputs: [String: GraphSpecNode] = [:]) -> GraphSpecNode {
        GraphSpecNode(TreeMerger.self, properties: ["tag": tag],
                      inputs: inputs.isEmpty ? [:] : [TreeMerger.inputPort: inputs]).port("output")
    }

    private func makeConsumer(tag: String, reading inputs: [String: GraphSpecNode] = [:]) throws -> ObjectID {
        try make(consumer(tag: tag, reading: inputs))
    }

    /// Wiring a node writes pending to every output of its target, so the states are put on
    /// last — a graph is wired before it fails, too.
    private func fail(_ nodeID: ObjectID, with message: String) throws {
        try database.node.select(nodeID: nodeID)
            .writeToOutputPort("output",
                               value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
    }

    /// What a node publishes when it did not run because an input is in error: a state with
    /// no message of its own, which is what the engine writes for a thrown
    /// `NodeError.inputValueInError`.
    private func carry(_ nodeID: ObjectID) throws {
        try database.node.select(nodeID: nodeID)
            .writeToOutputPort("output", value: .noValue(reason: .inputInError))
    }

    /// A port of this node carrying one reason, built rather than stored: the rule reads a
    /// port, and a test of the rule need not write one.
    private func port(_ nodeID: ObjectID, _ reason: NoValueReason) throws -> OutputPort {
        try NodeValue.noValue(reason: reason).asOutputPort(nodeID: nodeID,
                                                           outputSymbolID: "output".asSymbolID())
    }

    /// A node that reads its input by demanding a value, which is how a tool reads the files
    /// it compiles: what it publishes when there is none to be had is the engine's answer,
    /// not the node's.
    private func demanding(tag: String, reading inputs: [String: GraphSpecNode] = [:]) -> GraphSpecNode {
        GraphSpecNode(DemandingSampleTool.self, properties: ["tag": tag],
                      inputs: inputs.isEmpty ? [:] : [DemandingSampleTool.input: inputs]).port(DemandingSampleTool.output)
    }

    /// The product a chain ends in, reading `input`.
    private func product(reading input: GraphSpecNode) -> GraphSpecNode {
        GraphSpecNode(OutputFile.self, properties: [OutputFile.pathProperty: "output:/app"],
                      inputs: [OutputFile.inputPort: ["product": input]])
    }

    private func run(_ nodeID: ObjectID) throws {
        try database.node.select(nodeID: nodeID).makeNode().processWithPreCheck()
    }

    /// One header every consumer reads, each consumer feeding one shared sink: the shape a
    /// deleted header leaves behind, in miniature. Every node downstream of the header
    /// carries the cascade, so the graph holds `consumers + 2` failing nodes and one cause.
    @discardableResult
    private func makeCascade(consumers: Int) throws -> ObjectID {
        let source = try makeFile(path: "input:/shared.h")

        var parts: [String: GraphSpecNode] = [:]
        var carriers: [ObjectID] = []
        for index in 0 ..< consumers {
            let part = consumer(tag: "consumer \(index)", reading: ["header": .staticFile(at: "input:/shared.h")])
            parts["part \(index)"] = part
            carriers.append(try make(part))
        }
        carriers.append(try makeConsumer(tag: "sink", reading: parts))

        try fail(source, with: "the file is gone")
        for carrier in carriers {
            try carry(carrier)
        }

        return source
    }

    // MARK: - The report

    /// The failure B-74 describes: one deleted header stops every node that reads it, and an
    /// entry each would be hundreds of lines saying "an input is in error" and naming no fix.
    /// The report names the one node that can be fixed.
    func test_aCascadeIsReportedAsItsCauseAlone() throws {
        let source = try makeCascade(consumers: 20)
        XCTAssertEqual(Set(try ErrorReport.portsToReport(database: database).map(\.nodeID)).count, 22,
                       "the cause and every node downstream of it are in error")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].map(\.label), ["StaticFile #\(source) 'input:/shared.h'"])
    }

    /// The nodes that vanish from the report are still counted, so the size of the damage
    /// is on the page even though the list of it is not.
    func test_theCauseSaysHowMuchIsDownstreamOfIt() throws {
        let source = try makeCascade(consumers: 20)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0][0].downstreamCarrierCount, 21,
                       "twenty consumers and the sink they feed")
        XCTAssertEqual(ErrorReport.lines(for: captured[0][0]),
                       ["❌ StaticFile #\(source) 'input:/shared.h'",
                        "   · the file is gone",
                        "   · and 21 nodes downstream carry it",
                        ""])
    }

    func test_oneNodeDownstreamReadsAsOne() throws {
        let source   = try makeFile(path: "input:/shared.h")
        let consumer = try makeConsumer(tag: "only", reading: ["header": .staticFile(at: "input:/shared.h")])
        try fail(source, with: "the file is gone")
        try carry(consumer)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(ErrorReport.lines(for: captured[0][0]).filter { $0.contains("·") },
                       ["   · the file is gone", "   · and 1 node downstream carries it"])
    }

    /// A node that has something of its own to say is a cause, wherever it sits: its message
    /// names a fix the cause upstream does not.
    func test_aNodeWithAnErrorOfItsOwnIsReportedEvenBelowACause() throws {
        let source   = try makeFile(path: "input:/shared.h")
        let consumer = try makeConsumer(tag: "consumer", reading: ["header": .staticFile(at: "input:/shared.h")])
        try fail(source, with: "the file is gone")
        try fail(consumer, with: "no tool exists at '/usr/bin/nonesuch'")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0].map(\.label), ["StaticFile #\(source) 'input:/shared.h'", "TreeMerger #\(consumer)"])
        XCTAssertEqual(captured[0].map(\.downstreamCarrierCount), [0, 0])
    }

    /// A carrier whose cause is not in the graph has nothing upstream to blame, so the walk
    /// stops at it rather than reporting nothing. A chain is what folds: the topmost carrier
    /// stands in for the cause and the carriers wired below it fold onto it. Siblings of it
    /// would be a cause each — the collector is what keeps that shape from reaching a
    /// report, by taking every consumer of a node before the node itself.
    func test_aCarrierWithNothingFailingUpstreamStandsInForItsOwnCause() throws {
        let head = try makeConsumer(tag: "head")
        let tail = try makeConsumer(tag: "tail", reading: ["part": consumer(tag: "head")])
        try carry(head)
        try carry(tail)

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
        let consumer = try makeConsumer(tag: "consumer", reading: ["first":  .staticFile(at: "input:/first.h"),
                                                                   "second": .staticFile(at: "input:/second.h")])
        try fail(first, with: "the file is gone")
        try fail(second, with: "the file is gone")
        try carry(consumer)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured[0].map(\.label),
                       ["StaticFile #\(first) 'input:/first.h'", "StaticFile #\(second) 'input:/second.h'"])
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
        let consumer = try makeConsumer(tag: "consumer", reading: ["header": .staticFile(at: "input:/shared.h")])
        try fail(source, with: "the file is gone")
        try carry(consumer)

        engine.reportIdleTimeErrors()

        // The cause goes the way a collected node goes: its ports with it.
        _ = try database.outputPort.deleteAll(nodeID: source)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[1].map(\.label), ["TreeMerger #\(consumer)"])
    }

    // MARK: - The states a live graph writes

    /// A `StaticFile` nobody has pushed has no inputs, so nothing will ever make it run and
    /// its port holds the initializing state for good. A node that demands its value cannot
    /// produce one either, and says that — not that anything failed. The states are what the
    /// graph writes; the file is what the reader can act on, so the file is the line and the
    /// consumer is counted under it. `UnpushedFileReportingTests` is the rest of that rule.
    func test_anUnpushedFileIsTheLineAndItsConsumerIsCountedUnderIt() throws {
        let file     = try makeFile(path: "input:/clang.cfg")
        let consumer = try make(demanding(tag: "consumer", reading: ["config": .staticFile(at: "input:/clang.cfg")]))

        try run(consumer)

        XCTAssertEqual(try reason(of: file), .initializing)
        XCTAssertEqual(try reason(of: consumer), .inputNotProduced)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["StaticFile #\(file) 'input:/clang.cfg'"]])
        XCTAssertEqual(captured[0].map(\.downstreamCarrierCount), [1])
    }

    /// The kind the port carries, which is the reason in the form the graph stores.
    private func reason(of nodeID: ObjectID, port: String = "output") throws -> OutputPort.ValueKind? {
        try database.outputPort.select(nodeID: nodeID, nameSymbolID: port.asSymbolID())?.valueKind
    }

    // MARK: - A pipeline, processed

    /// The chain a compile is: a source file, a compiler, a linker, a product. With the file
    /// nobody pushed at the top of it, nothing in the chain has failed — so however deep the
    /// chain runs, the one thing to say about it is the file at the top.
    func test_anUnpushedFileIsNamedOnceHoweverDeepTheChain() throws {
        let file         = try makeFile(path: "input:/main.c")
        let compilerTree = demanding(tag: "compiler", reading: ["source": .staticFile(at: "input:/main.c")])
        let linkerTree   = demanding(tag: "linker", reading: ["object": compilerTree])
        let compiler     = try make(compilerTree)
        let linker       = try make(linkerTree)
        let product      = try make(product(reading: linkerTree))

        try run(compiler)
        try run(linker)
        try run(product)

        XCTAssertEqual(try reason(of: compiler), .inputNotProduced)
        XCTAssertEqual(try reason(of: linker), .inputNotProduced, "the state carries down the chain")
        XCTAssertEqual(try reason(of: product, port: OutputFile.statusOutputPort), .inputNotProduced)

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.map { $0.map(\.label) }, [["StaticFile #\(file) 'input:/main.c'"]])
        XCTAssertEqual(captured[0].map(\.downstreamCarrierCount), [3],
                       "the compiler, the linker and the product below them")
    }

    /// The same chain with a compile that failed: one node has something to say and the rest
    /// carry it, so the report names the compiler once and counts the two below it.
    func test_aFailedCompileIsNamedOnceWithTheChainCountedUnderIt() throws {
        let compilerTree = demanding(tag: "compiler")
        let linkerTree   = demanding(tag: "linker", reading: ["object": compilerTree])
        let compiler     = try make(compilerTree)
        let linker       = try make(linkerTree)
        let product      = try make(product(reading: linkerTree))

        try fail(compiler, with: "undefined symbol 'main'")

        try run(linker)
        try run(product)

        XCTAssertEqual(try reason(of: linker), .inputInError)
        XCTAssertEqual(try reason(of: product, port: OutputFile.statusOutputPort),
                       .inputInError, "the product carries the failure rather than repeating it")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].map(\.label), ["DemandingSampleTool #\(compiler)"])
        XCTAssertEqual(captured[0].map(\.downstreamCarrierCount), [2])
        XCTAssertEqual(captured[0][0].items,
                       [ErrorReport.Item(ports: ["output"], message: "undefined symbol 'main'")])
    }

    /// A tree pipeline is a chain like any other: a merger that could not merge because one
    /// of its trees failed says so as a state, rather than repeating the sentence the tool
    /// wrote, and the report still names the tool once.
    func test_aFailureThroughATreeIsNamedOnceWithTheTreeCountedUnderIt() throws {
        let toolTree   = demanding(tag: "tool")
        let mergerTree = GraphSpecNode(TreeMerger.self, inputs: [TreeMerger.inputPort: ["assets": toolTree]])
            .port(TreeMerger.outputPort)
        let tool       = try make(toolTree)
        let merger     = try make(mergerTree)
        let product    = try make(product(reading: mergerTree))

        try fail(tool, with: "xcstringstool failed")

        try run(merger)
        try run(product)

        XCTAssertEqual(try reason(of: merger, port: TreeMerger.outputPort), .inputInError,
                       "the merger carries the failure rather than repeating its message")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].map(\.label), ["DemandingSampleTool #\(tool)"])
        XCTAssertEqual(captured[0].map(\.downstreamCarrierCount), [2])
    }

    // MARK: - The rule

    /// One state means "someone else failed", and the report asks the port which state it is
    /// in rather than reading what it says.
    func test_onlyTheInputInErrorStateIsCarried() throws {
        let nodeID = try makeConsumer(tag: "any")

        XCTAssertTrue(ErrorReport.isCarriedFromAnInput(try port(nodeID, .inputInError)))
        XCTAssertFalse(ErrorReport.isCarriedFromAnInput(try port(nodeID, .error(messageDataObjectHash: "boom".intern()))))
        XCTAssertFalse(ErrorReport.isCarriedFromAnInput(try port(nodeID, .initializing)))
        XCTAssertFalse(ErrorReport.isCarriedFromAnInput(try port(nodeID, .pending)))
        XCTAssertFalse(ErrorReport.isCarriedFromAnInput(try port(nodeID, .inputNotProduced)))
    }

    /// The second way of carrying someone else's state: a node stopped by a value that was
    /// never produced. Read by case, like the first.
    func test_onlyTheInputNotProducedStateIsCarriedFromAnAbsence() throws {
        let nodeID = try makeConsumer(tag: "any")

        XCTAssertTrue(ErrorReport.isCarriedFromAnAbsentInput(try port(nodeID, .inputNotProduced)))
        XCTAssertFalse(ErrorReport.isCarriedFromAnAbsentInput(try port(nodeID, .inputInError)))
        XCTAssertFalse(ErrorReport.isCarriedFromAnAbsentInput(try port(nodeID, .initializing)))
        XCTAssertFalse(ErrorReport.isCarriedFromAnAbsentInput(try port(nodeID, .pending)))
    }

    /// A state that is not a failure is not reported: a node between its creation and its
    /// first processing would otherwise put every fresh graph in the error report, and a
    /// node that did not run says the one sentence there is to say for it.
    func test_whatEachStateReportsAsAMessage() throws {
        let nodeID = try makeConsumer(tag: "any")

        XCTAssertNil(ErrorReport.reportableMessage(of: try port(nodeID, .initializing)))
        XCTAssertNil(ErrorReport.reportableMessage(of: try port(nodeID, .pending)))
        XCTAssertEqual(ErrorReport.reportableMessage(of: try port(nodeID, .inputInError)), carried)
        XCTAssertEqual(ErrorReport.reportableMessage(of: try port(nodeID, .error(messageDataObjectHash: "boom".intern()))),
                       "boom")
    }

    /// A node carrying an input error *and* something of its own is a cause: the something
    /// of its own is what a reader can act on.
    func test_aNodeIsACarrierOnlyWhenEveryPortIsCarried() throws {
        let source   = try makeFile(path: "input:/shared.h")
        let consumer = try makeConsumer(tag: "consumer", reading: ["header": .staticFile(at: "input:/shared.h")])
        try fail(source, with: "the file is gone")
        try carry(consumer)
        try database.node.select(nodeID: consumer)
            .writeToOutputPort("errorLog",
                               value: .noValue(reason: .error(messageDataObjectHash: try "and a log".intern())))

        let byNode = Dictionary(grouping: try ErrorReport.portsToReport(database: database), by: \.nodeID)

        XCTAssertEqual(ErrorReport.causes(amongErrorPorts: byNode, database: database),
                       [source: 0, consumer: 0])
    }
}
