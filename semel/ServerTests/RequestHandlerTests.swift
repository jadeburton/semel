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

    /// The version a role-only `Hello` carries is read from `SemelProtocol`, not copied into
    /// this module. A default argument would be copied: the compiler emits the
    /// default-argument generator into every caller's object file with the number folded in,
    /// so a caller whose object survives a change to `ProtocolVersion.current` disagrees with
    /// one that is recompiled, and the linker picks either copy. `ProtocolVersion.current` on
    /// the right-hand side is the point of the test — it is a load from the protocol module at
    /// run time, so a stale copy on the left fails it (B-84).
    func test_helloWithNoVersionNamedCarriesTheProtocolModulesNumber() {
        XCTAssertEqual(Hello(role: .daemon).protocolVersion, ProtocolVersion.current)
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
        let (response, body) = try daemon(.debug(cacheKey: nil))

        XCTAssertEqual(response, .debug)
        let text = String(decoding: try XCTUnwrap(body), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("BUILD GRAPH STATE ("), text)
    }

    /// B-13. The same verb with a key answers that entry's key material, so a mismatch
    /// between two machines is a diff of two texts rather than two hashes.
    func test_debugWithAKeyReturnsThatEntrysKeyMaterial() throws {
        let key = try storeOneCacheEntry()

        let (response, body) = try daemon(.debug(cacheKey: key))

        XCTAssertEqual(response, .debug)
        let text = String(decoding: try XCTUnwrap(body), as: UTF8.self)
        XCTAssertTrue(text.contains("cache entry \(key)"), text)
        XCTAssertTrue(text.contains("node ConfigFilter@\(ConfigFilter.implementationVersion)"), text)
        XCTAssertTrue(text.contains(#"property {"key":"prefix","value":"sample"}"#), text)
        XCTAssertTrue(text.contains(#"input {"port":"input","#), text)
    }

    func test_debugWithAKeyNothingIsStoredUnderSaysSo() throws {
        let (_, body) = try daemon(.debug(cacheKey: String(repeating: "f", count: 64)))

        XCTAssertTrue(String(decoding: try XCTUnwrap(body), as: UTF8.self).contains("no cache entry"))
    }

    /// One entry, stored the way a build stores one: the material is taken of a real
    /// node's real input and the key is taken of the material.
    private func storeOneCacheEntry() throws -> String {
        let (record, _) = try GraphSpecNode.parse("ConfigFilter(prefix: 'sample')").findOrCreateMatchingNode()
        let node  = try record.makeNode()
        let input = ProcessInput(inputValues: ["input": ["wire0": .value(try "sample.key=1".intern())]])
        let material = try node.buildCacheKeyMaterial(input: input)
        try node.saveCacheForAllInputsAndOutputs(
            keyMaterial: material, processingDuration: 0.1,
            output: AppliedOutput(outputValues: ["output": .value(try "key=1".intern())],
                                  specTable: GraphSpecTable(inputWireSpecs: [:], rows: [:])))
        return try material.cacheKey()
    }

    /// The findings are the reply's body for the reason the graph description is: a badly
    /// broken graph has one per node, and the frame's JSON section is capped at a megabyte.
    func test_checkReturnsItsFindingsAsTheReplyBody() throws {
        let (node, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/app')").findOrCreateMatchingNode()

        let (response, body) = try daemon(.check)

        guard case .check = response else {
            return XCTFail("expected check, got \(response)")
        }
        let findings = try MessageCoder.decode([CheckFinding].self, from: try XCTUnwrap(body))
        XCTAssertEqual(findings, [
            CheckFinding(kind: .productWithNoProducer,
                         subject: "OutputFile #\(try node.requireID()) 'output:/app'",
                         sentence: "nothing is wired to its required input port 'input', so it can never be produced"),
        ])
    }

    func test_checkOverAGraphWithNothingWrongWithItAnswersNoFindings() throws {
        let (response, body) = try daemon(.check)

        XCTAssertEqual(response, .check(scheduledNodes: 0))
        XCTAssertEqual(try MessageCoder.decode([CheckFinding].self, from: try XCTUnwrap(body)), [])
    }

    /// The count comes from the same read as the findings, and is what lets a client say
    /// whether a finding about wiring describes a defect or work the engine has not
    /// finished. The reply carries it; nothing on this side waits or refuses.
    func test_checkReportsHowManyNodesWereStillScheduled() throws {
        let (node, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/app')").findOrCreateMatchingNode()

        XCTAssertEqual(try daemon(.check).0, .check(scheduledNodes: 1))

        try database.node.updateScheduled(nodeID: try node.requireID(), scheduled: false)

        XCTAssertEqual(try daemon(.check).0, .check(scheduledNodes: 0))
    }

    func test_toolsListsEveryNamespaceEvenWhenNoToolIsInstalled() throws {
        ToolRunnerRegistry.instance = ToolRunnerRegistry()

        let (response, _) = try daemon(.tools(platform: "macos"))

        guard case .tools(let namespaces) = response else {
            return XCTFail("expected tools, got \(response)")
        }
        XCTAssertEqual(namespaces.map(\.namespace), ToolNamespaceRegistry.all.map(\.namespace))
        XCTAssertTrue(namespaces.allSatisfy { $0.descriptors.isEmpty })
    }

    /// B-109. A namespace is selected when a ConfigFilter with its prefix is resident —
    /// whether or not the settings file exists.
    func test_toolsSaysWhichNamespacesTheGraphSelects() throws {
        ToolNamespaceRegistry.register(.init(namespace: "clang.compiler", toolName: "clang"))
        ToolNamespaceRegistry.register(.init(namespace: "swift.linker", toolName: "swiftc"))
        _ = try GraphSpecNode.parse("ConfigFilter(prefix: 'clang.compiler')").findOrCreateMatchingNode()

        let (response, _) = try daemon(.tools(platform: "macos"))

        guard case .tools(let namespaces) = response else {
            return XCTFail("expected tools, got \(response)")
        }
        let selected = Dictionary(uniqueKeysWithValues: namespaces.map { ($0.namespace, $0.selected) })
        XCTAssertEqual(selected["clang.compiler"], true)
        XCTAssertEqual(selected["swift.linker"], false)
    }

    /// By path, not by id: `b.c`'s node is made first and so has the lower id.
    func test_errorsReturnsOneRecordPerFailingNodeSortedByLabel() throws {
        let second = try makeFailingFile(path: "input:/b.c", message: "second")
        let first  = try makeFailingFile(path: "input:/a.c", message: "first")

        let (response, _) = try daemon(.errors(product: nil))

        XCTAssertEqual(response, .errors(records: [
            fileRecord(first, message: "first"),
            fileRecord(second, message: "second"),
        ]))
    }

    /// Twelve nodes of one type, whose labels differ only by id: the reply orders them by
    /// node, and the idle-time event lists them identically, which is what the two orderings
    /// promise each other. Twelve rather than a handful so that ids compared as text — `#10`
    /// before `#2` — would show.
    func test_errorsWithTiedLabelsAreOrderedByNodeInBothTheReplyAndTheEvent() throws {
        let messages = (1...12).map { "boom \($0)" }
        for message in messages {
            try makeFailingMerger(message: message)
        }

        let (response, _) = try daemon(.errors(product: nil))
        engine.reportIdleTimeErrors()

        guard case .errors(let records) = response else {
            return XCTFail("expected errors, got \(response)")
        }
        XCTAssertEqual(records.map(\.document), messages.map(ErrorDocument.failure),
                       "the nodes were created in message order, so node order is message order")
        XCTAssertEqual(sink.events, [.daemon(.errors(records: records))])
    }

    /// B-110. Three nodes of one type carrying one document are one record naming all
    /// three, in the reply and in the event alike, and the record's facts say which.
    func test_nodesOfOneTypeWithOneMessageAreOneRecordInBothTheReplyAndTheEvent() throws {
        for tag in ["a", "b", "c"] {
            try makeFailingMerger(message: "boom", tag: tag)
        }

        let (response, _) = try daemon(.errors(product: nil))
        engine.reportIdleTimeErrors()

        guard case .errors(let records) = response else {
            return XCTFail("expected errors, got \(response)")
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].facts.nodeIDs.count, 3)
        XCTAssertEqual(records[0].facts.nodeType, "TreeMerger")
        XCTAssertEqual(sink.events, [.daemon(.errors(records: records))])
    }

    /// B-74. Twenty nodes reading one deleted file all say "an input is in error" and none
    /// of them can be fixed; the reply names the file once and counts the rest. The event
    /// says the same, because both are built by `ErrorReport`.
    func test_errorsFoldsACascadeOntoItsCauseInBothTheReplyAndTheEvent() throws {
        let sourceTree  = GraphSpecNode.staticFile(at: "input:/shared.h")
        let (source, _) = try sourceTree.findOrCreateMatchingNode()
        var carriers: [NodeRecord] = []
        for index in 1...20 {
            // Wired before it fails: connecting writes pending to every output of the target.
            let (carrier, _) = try GraphSpecNode(TreeMerger.self, properties: ["tag": "\(index)"],
                                                 inputs: [TreeMerger.inputPort: ["header": sourceTree]])
                .findOrCreateMatchingNode()
            carriers.append(carrier)
        }
        try source.writeToOutputPort("output", value: .noValue(
            reason: try .failure("the file is gone")))
        for carrier in carriers {
            // The state a node publishes when it did not run because its input failed: no
            // message of its own, which is what makes it foldable.
            try carrier.writeToOutputPort("output", value: .noValue(reason: .inputInError))
        }

        let (response, _) = try daemon(.errors(product: nil))
        engine.reportIdleTimeErrors()

        XCTAssertEqual(response, .errors(records: [
            fileRecord(try source.requireID(), message: "the file is gone", carried: 20),
        ]))
        guard case .errors(let records) = response else {
            return XCTFail("expected errors, got \(response)")
        }
        XCTAssertEqual(sink.events, [.daemon(.errors(records: records))])
    }

    func test_errorsIsEmptyWhenNothingFailed() throws {
        XCTAssertEqual(try daemon(.errors(product: nil)).0, .errors(records: []))
    }

    // MARK: - The products an error stops (B-142)

    /// `input:/a.c` feeds two products and `input:/b.c` none. Wired before either fails, as
    /// a graph is wired before it fails.
    private func makeFailuresUnderTwoProducts() throws -> (feeding: ObjectID, orphan: ObjectID) {
        for path in ["output:/app/lib", "output:/app/bin"] {
            _ = try GraphSpecNode(OutputFile.self, properties: [OutputFile.pathProperty: path],
                                  inputs: [OutputFile.inputPort: ["product": .staticFile(at: "input:/a.c")]])
                .findOrCreateMatchingNode()
        }
        return (try makeFailingFile(path: "input:/a.c", message: "first"),
                try makeFailingFile(path: "input:/b.c", message: "second"))
    }

    func test_eachRecordNamesTheProductsItStopsInPathOrder() throws {
        let (feeding, orphan) = try makeFailuresUnderTwoProducts()

        XCTAssertEqual(try daemon(.errors(product: nil)).0, .errors(records: [
            fileRecord(feeding, message: "first",
                       products: [StoppedProduct(path: "output:/app/bin"), StoppedProduct(path: "output:/app/lib")]),
            fileRecord(orphan, message: "second"),
        ]))
    }

    /// The idle-time report names them too, through the same walk.
    func test_theIdleTimeEventNamesTheProducts() throws {
        _ = try makeFailuresUnderTwoProducts()

        engine.reportIdleTimeErrors()

        guard case .daemon(.errors(let records))? = sink.events.first else {
            return XCTFail("expected an error event, got \(sink.events)")
        }
        XCTAssertEqual(records.map { $0.products.map(\.path) }, [["output:/app/bin", "output:/app/lib"], []])
    }

    /// Filtered on the server: only the records stopping the product are sent.
    func test_errorsForOneProductAnswersOnlyTheRecordsStoppingIt() throws {
        let (feeding, _) = try makeFailuresUnderTwoProducts()

        guard case .errors(let records) = try daemon(.errors(product: "app/bin")).0 else {
            return XCTFail("expected errors")
        }
        XCTAssertEqual(records.map(\.facts.nodeIDs), [[feeding]])
    }

    /// A folder holding products is no product, nor is a path nothing stands at; either is
    /// an error naming the path, where an empty answer would read as "nothing is wrong".
    func test_errorsForAPathThatIsNoProductIsAnErrorNamingIt() throws {
        _ = try makeFailuresUnderTwoProducts()

        XCTAssertEqual(daemonError(.errors(product: "app")), .notAProduct(path: "output:/app"))
        XCTAssertEqual(daemonError(.errors(product: "app/nothing")), .notAProduct(path: "output:/app/nothing"))
    }

    // MARK: - Events

    func test_engineErrorReportsReachTheSinkAsRecords() throws {
        let file = try makeFailingFile(path: "input:/a.c", message: "boom")

        engine.reportIdleTimeErrors()

        XCTAssertEqual(sink.events, [
            .daemon(.errors(records: [fileRecord(file, message: "boom")])),
        ])
    }

    func test_noticesReachTheSink() {
        BuildEngine.notice("output:/app: written")

        XCTAssertEqual(sink.events, [.daemon(.notice(line: "output:/app: written"))])
    }

    func test_theSettleSummaryReachesTheSinkAsItsFourTotals() {
        engine.settleReporter(SettleSummary(scheduled: 12, computed: 3, fromCache: 9, errors: 0))

        XCTAssertEqual(sink.events, [.daemon(.settled(scheduled: 12, computed: 3, fromCache: 9, errors: 0))])
    }

    /// The summary's error count is the graph's whole current error state, counted per
    /// cause as the `errors` report counts its blocks, so a line and the report drawn from
    /// the reply to `errors` moments later say the same number.
    func test_theSettleTimeErrorCountMatchesWhatTheErrorsVerbWouldAnswer() throws {
        try makeFailingFile(path: "input:/a.c", message: "boom")
        try makeFailingFile(path: "input:/b.c", message: "bang")

        guard case .errors(let records) = try daemon(.errors(product: nil)).0 else {
            return XCTFail("expected errors")
        }
        let verbCount = Set(records.flatMap { $0.document.causes.map(\.mergeKey) }).count

        XCTAssertEqual(engine.reportIdleTimeErrors(), verbCount)
        XCTAssertEqual(verbCount, 2)
    }

    // MARK: - Helpers

    /// The record a failing file's node is answered as.
    private func fileRecord(_ nodeID: ObjectID, message: String, products: [StoppedProduct] = [], carried: Int = 0) -> ErrorRecord {
        ErrorRecord(document: .failure(message), products: products,
                    facts: ErrorFacts(nodeType: "StaticFile", nodeIDs: [nodeID], ports: ["output"], carrierCount: carried))
    }

    @discardableResult
    private func makeFailingFile(path: String, message: String) throws -> ObjectID {
        let (nodeRecord, _) = try GraphSpecNode.staticFile(at: path).findOrCreateMatchingNode()
        try nodeRecord.writeToOutputPort("output",
                                         value: .noValue(reason: try .failure(message)))
        return try nodeRecord.requireID()
    }

    /// A node with no path is labelled by its type and id, so several of one type share a
    /// label apart from the id, which the sort leaves out. Ordering them by that alone leaves them in the order the error map was
    /// walked in, and that order is seeded per process — the reply would list them one way
    /// on Monday and another on Tuesday, and the event could disagree with the reply in
    /// the same run. The node breaks the tie, in both places.
    private func makeFailingMerger(message: String, tag: String? = nil) throws {
        // A property of its own, because two nodes of one type with the same properties are
        // one node to the graph; `path` is deliberately not it, since that is what a label
        // would be made of.
        let (nodeRecord, _) = try GraphSpecNode(TreeMerger.self, properties: ["tag": tag ?? message])
            .findOrCreateMatchingNode()
        try nodeRecord.writeToOutputPort(TreeMerger.outputPort,
                                         value: .noValue(reason: try .failure(message)))
    }
}
