//
//  RequestHandlerTests.swift
//  SemelServerTests
//
//  The bottleneck between the wire and the engine, driven with typed messages against a
//  real in-memory engine. The file verbs have their own file; this one covers the
//  handshake, batches, the engine verbs and event routing.
//

@testable import SemelCore
@testable import SemelServer
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

final class RequestHandlerTests: RequestHandlerTestCase {

    // MARK: - Hello

    func test_helloIsAcceptedWithTheServerVersionAndDatabasePath() {
        let (response, _) = handler.handle(.hello(Hello(role: .daemon)), body: nil, session: session)

        XCTAssertEqual(response, .hello(.accepted(serverVersion: Semel.version, databasePath: "/tmp/test-graph.sqlite")))
    }

    func test_helloWithAnotherProtocolVersionIsRejectedNamingBoth() {
        let (response, _) = handler.handle(.hello(Hello(protocolVersion: 99, role: .daemon)), body: nil, session: session)

        XCTAssertEqual(response, .hello(.rejected(reason: .versionMismatch(client: 99, server: ProtocolVersion.current))))
    }

    func test_helloForARoleNotOfferedIsRejected() {
        let (response, _) = handler.handle(.hello(Hello(role: .cache)), body: nil, session: session)

        XCTAssertEqual(response, .hello(.rejected(reason: .roleNotOffered(role: .cache))))
    }

    // MARK: - Batches and subscription

    func test_batchesAreCountedOnTheSession() throws {
        try daemon(.beginBatch)
        try daemon(.beginBatch)
        try daemon(.endBatch)

        XCTAssertEqual(session.openBatchDepth, 1)
    }

    func test_anUnmatchedEndBatchIsIgnored() throws {
        let (response, _) = try daemon(.endBatch)

        XCTAssertEqual(response, .ok)
        XCTAssertEqual(session.openBatchDepth, 0)

        try daemon(.beginBatch)
        try daemon(.endBatch)

        XCTAssertEqual(session.openBatchDepth, 0)
    }

    func test_endingASessionClosesItsOpenBatches() throws {
        try daemon(.beginBatch)
        try daemon(.beginBatch)

        handler.endSession(session)

        XCTAssertEqual(session.openBatchDepth, 0)
    }

    func test_subscribeMarksTheSession() throws {
        let (response, _) = try daemon(.subscribe)

        XCTAssertEqual(response, .ok)
        XCTAssertTrue(session.isSubscribed)
    }

    // MARK: - Engine verbs

    func test_nudgeAnswersOk() throws {
        XCTAssertEqual(try daemon(.nudge).0, .ok)
    }

    /// The reply names the copy of the graph the reset left behind. The fixture's graph is
    /// in memory and has no file, so there is no path to name.
    func test_resetAnswersWithWhereTheDiscardedGraphWent() throws {
        XCTAssertEqual(try daemon(.reset(clearCache: false)).0, .reset(archivedGraphPath: nil))
    }

    /// The fixture engine has no processing loop, so there is nothing to settle and the
    /// wait returns at once. It is answered before the serial queue, so this also pins
    /// that a wait never reaches the dispatcher.
    func test_waitAnswersOkWhenTheEngineIsIdle() throws {
        XCTAssertEqual(try daemon(.wait).0, .ok)
    }

    /// The description is the reply's body, not a field in its JSON: it runs to megabytes
    /// on a real graph, and the JSON section of a frame is capped at one.
    func test_debugReturnsTheGraphDescriptionAsTheReplyBody() throws {
        let (response, body) = try daemon(.debug)

        XCTAssertEqual(response, .debug)
        let text = String(decoding: try XCTUnwrap(body), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("BUILD GRAPH STATE ("), text)
    }

    func test_toolsListsEveryNamespaceEvenWhenNoToolIsInstalled() throws {
        ToolRunnerRegistry.instance = ToolRunnerRegistry()

        let (response, _) = try daemon(.tools)

        guard case .tools(let namespaces) = response else {
            return XCTFail("expected tools, got \(response)")
        }
        XCTAssertEqual(namespaces.map(\.namespace), ToolNamespaceRegistry.all.map(\.namespace))
        XCTAssertTrue(namespaces.allSatisfy { $0.descriptors.isEmpty })
    }

    func test_errorsReturnsOneRecordPerFailingNodeSortedByLabel() throws {
        try makeFailingFile(path: "input:/b.c", message: "second")
        try makeFailingFile(path: "input:/a.c", message: "first")

        let (response, _) = try daemon(.errors)

        XCTAssertEqual(response, .errors(records: [
            ErrorRecord(label: "StaticFile  'input:/a.c'", entries: [ErrorEntry(ports: ["output"], message: "first")]),
            ErrorRecord(label: "StaticFile  'input:/b.c'", entries: [ErrorEntry(ports: ["output"], message: "second")]),
        ]))
    }

    /// Six nodes of one type, so every label ties: the reply orders them by node, and the
    /// idle-time event lists them identically, which is what the two orderings promise
    /// each other.
    func test_errorsWithTiedLabelsAreOrderedByNodeInBothTheReplyAndTheEvent() throws {
        let messages = (1...6).map { "boom \($0)" }
        for message in messages {
            try makeFailingMerger(message: message)
        }

        let (response, _) = try daemon(.errors)
        engine.reportIdleTimeErrors()

        guard case .errors(let records) = response else {
            return XCTFail("expected errors, got \(response)")
        }
        XCTAssertEqual(records.map { $0.entries.first?.message }, messages,
                       "the nodes were created in message order, so node order is message order")
        XCTAssertEqual(sink.events, [.daemon(.errors(records: records))])
    }

    /// B-74. Twenty nodes reading one deleted file all say "an input is in error" and none
    /// of them can be fixed; the reply names the file once and counts the rest. The event
    /// says the same, because both are built by `ErrorReport`.
    func test_errorsFoldsACascadeOntoItsCauseInBothTheReplyAndTheEvent() throws {
        let source = try NodeRecord.createNode(database: database, kind: StaticFile.kind,
                                               properties: ["path": "input:/shared.h"], graphSpec: nil)
        var carriers: [NodeRecord] = []
        for index in 1...20 {
            let carrier = try NodeRecord.createNode(database: database, kind: TreeMerger.kind,
                                                    properties: ["tag": "\(index)"], graphSpec: nil)
            // Wired before it fails: connecting writes pending to every output of the target.
            try Wire.connectWire(database: database,
                                 fromNodeID: try source.requireID(),
                                 fromSymbolID: "output".asSymbolID(),
                                 toNodeID: try carrier.requireID(),
                                 toSymbolID: "input".asSymbolID(),
                                 name: "header".asSymbolID())
            carriers.append(carrier)
        }
        try source.writeToOutputPort("output", value: .noValue(
            reason: .error(messageDataObjectHash: try "the file is gone".intern())))
        for carrier in carriers {
            // The state a node publishes when it did not run because its input failed: no
            // message of its own, which is what makes it foldable.
            try carrier.writeToOutputPort("output", value: .noValue(reason: .inputInError))
        }

        let (response, _) = try daemon(.errors)
        engine.reportIdleTimeErrors()

        XCTAssertEqual(response, .errors(records: [
            ErrorRecord(label: "StaticFile  'input:/shared.h'",
                        entries: [ErrorEntry(ports: ["output"], message: "the file is gone")],
                        downstreamCarrierCount: 20),
        ]))
        guard case .errors(let records) = response else {
            return XCTFail("expected errors, got \(response)")
        }
        XCTAssertEqual(sink.events, [.daemon(.errors(records: records))])
    }

    func test_errorsIsEmptyWhenNothingFailed() throws {
        XCTAssertEqual(try daemon(.errors).0, .errors(records: []))
    }

    // MARK: - Events

    func test_engineErrorReportsReachTheSinkAsRecords() throws {
        try makeFailingFile(path: "input:/a.c", message: "boom")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(sink.events, [
            .daemon(.errors(records: [ErrorRecord(label: "StaticFile  'input:/a.c'",
                                                  entries: [ErrorEntry(ports: ["output"], message: "boom")])])),
        ])
    }

    func test_noticesReachTheSink() {
        BuildEngine.notice("output:/app: written")

        XCTAssertEqual(sink.events, [.daemon(.notice(line: "output:/app: written"))])
    }

    // MARK: - Helpers

    private func makeFailingFile(path: String, message: String) throws {
        let nodeRecord = try NodeRecord.createNode(database: database, kind: StaticFile.kind,
                                                   properties: ["path": path], graphSpec: nil)
        try nodeRecord.writeToOutputPort("output",
                                         value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
    }

    /// A node with no path is labelled by its type alone, so several of one type share a
    /// label. Ordering them by label alone leaves them in the order the error map was
    /// walked in, and that order is seeded per process — the reply would list them one way
    /// on Monday and another on Tuesday, and the event could disagree with the reply in
    /// the same run. The node breaks the tie, in both places.
    private func makeFailingMerger(message: String) throws {
        // A property of its own, because two nodes of one type with the same properties are
        // one node to the graph; `path` is deliberately not it, since that is what a label
        // would be made of.
        let nodeRecord = try NodeRecord.createNode(database: database, kind: TreeMerger.kind,
                                                   properties: ["tag": message], graphSpec: nil)
        try nodeRecord.writeToOutputPort(TreeMerger.outputPort,
                                         value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
    }
}
