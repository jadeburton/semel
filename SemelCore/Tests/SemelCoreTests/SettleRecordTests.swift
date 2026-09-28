//
//  SettleRecordTests.swift
//  SemelCore
//
//  B-91. The settle summary counts nodes; the record names them, and names the wire that
//  woke each. These build one small graph — a pushed config file, two `ConfigFilter`s
//  selecting two prefixes of it, a `SampleTool` under each — on a real processing loop,
//  as SettleSummaryTests does, and change one prefix at a time: the filter that selects
//  it passes on a new value and its tool runs; the other filter passes on what it passed
//  before, and its tool is woken and answered from the cache.
//

@testable import SemelCore
import SemelNodeKit
import XCTest

final class SettleRecordTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    private let configPath = "input:/cfg/semel.config"

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        // Above the cache's floor, so the first build stores what the later ones hit.
        SampleTool.processingDurationForTests = 0.02
        engine.startProcessingLoop()
    }

    override func tearDown() {
        SampleTool.processingDurationForTests = 0
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    // MARK: - The graph

    private struct Graph {
        let file:    ObjectID
        let filterA: ObjectID
        let filterB: ObjectID
        let toolA:   ObjectID
        let toolB:   ObjectID
    }

    /// The same sequence `FilePlugin.handlePush` runs per file.
    private func push(_ contents: String) throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders("cfg", pinned: true)
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(configPath)')").findOrCreateMatchingNode()
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
        _ = try file.replaceContent(try contents.intern())
    }

    private func filterSpec(_ prefix: String) -> String {
        "ConfigFilter(prefix: '\(prefix)', input: ['config': StaticFile(path: '\(configPath)').output]).output"
    }

    private func nodeID(_ spec: String) throws -> ObjectID {
        try GraphSpecNode.parse(spec).findOrCreateMatchingNode().fromNode.requireID()
    }

    private func settle() async {
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()
    }

    /// Built once and settled: every node new and run.
    ///
    /// Built inside one batch, as a push of several files is: the loop is running, and
    /// without the batch it could settle between two of the nodes — or run a tool, then
    /// answer it again from the entry that run had just stored, which the record reports
    /// as a cache hit. One batch, one settle, one record of every node.
    private func buildGraph() async throws -> Graph {
        engine.beginBatch()
        let graph: Graph
        do {
            try push("a.x=1\nb.y=1\n")
            graph = Graph(file:    try nodeID("StaticFile(path: '\(configPath)').output"),
                          filterA: try nodeID(filterSpec("a")),
                          filterB: try nodeID(filterSpec("b")),
                          toolA:   try nodeID("SampleTool(configuration: ['cfg': \(filterSpec("a"))]).output"),
                          toolB:   try nodeID("SampleTool(configuration: ['cfg': \(filterSpec("b"))]).output"))
        } catch {
            engine.endBatch()
            throw error
        }
        engine.endBatch()
        await settle()
        return graph
    }

    private var record: SettleRecord {
        get throws { try XCTUnwrap(engine.lastSettleRecord, "a settle that did work leaves a record") }
    }

    // MARK: - The record

    /// What a restarted server has: a graph, and no settle to explain.
    func test_anEngineThatHasNotSettledHasNoRecord() throws {
        // A new database installs itself as the shared one, which the running loop reads.
        engine.waitUntilIdleBlocking()
        let fresh = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)

        XCTAssertNil(fresh.lastSettleRecord)
        XCTAssertNil(fresh.explain(nodeID: 1))
    }

    func test_theFirstBuildRecordsEveryNodeAsNewAndComputed() async throws {
        let graph = try await buildGraph()
        let record = try record

        for nodeID in [graph.filterA, graph.filterB, graph.toolA, graph.toolB] {
            XCTAssertEqual(record.outcomes[nodeID], .computed)
            XCTAssertTrue(record.created.contains(nodeID))
        }
        XCTAssertNil(record.outcomes[graph.file], "a pushed file does not run")
    }

    /// The change to `a.x` reaches toolA as a changed value; `b.y` did not change, so
    /// filterB passes on what it passed before, and toolB is woken by a wire that brought
    /// nothing new — and the cache answers it.
    func test_theRecordNamesTheWireThatWokeEachNodeAndWhetherItsValueMoved() async throws {
        let graph = try await buildGraph()

        try push("a.x=2\nb.y=1\n")
        await settle()
        let record = try record

        XCTAssertEqual(record.outcomes[graph.filterA], .computed)
        XCTAssertEqual(record.outcomes[graph.filterB], .computed)
        XCTAssertEqual(record.outcomes[graph.toolA], .computed)
        XCTAssertEqual(record.outcomes[graph.toolB], .fromCache)
        XCTAssertTrue(record.created.isEmpty, "nothing new in a rebuild")
        XCTAssertEqual(record.changedSources, [graph.file], "the push is the source that changed")

        let toolAWake = try XCTUnwrap(record.wakes[graph.toolA]?.first)
        XCTAssertEqual(record.wakes[graph.toolA]?.count, 1)
        XCTAssertEqual(toolAWake.fromNodeID, graph.filterA)
        XCTAssertEqual(toolAWake.toPortSymbolID.resolveSymbol(), "configuration")
        XCTAssertEqual(toolAWake.wireNameSymbolID.resolveSymbol(), "cfg")
        XCTAssertEqual(toolAWake.fromPortSymbolID.resolveSymbol(), "output")
        XCTAssertEqual(toolAWake.change, .changed)

        XCTAssertEqual(record.wakes[graph.toolB]?.map(\.change), [.unchanged])
        XCTAssertEqual(record.wakes[graph.filterA]?.map(\.fromNodeID), [graph.file])
        XCTAssertEqual(record.wakes[graph.filterA]?.map(\.change), [.changed])
    }

    func test_theNextSettleReplacesTheRecord() async throws {
        let graph = try await buildGraph()
        try push("a.x=2\nb.y=1\n")
        await settle()
        XCTAssertEqual(try record.outcomes[graph.toolA], .computed)

        try push("a.x=2\nb.y=2\n")
        await settle()
        let record = try record

        XCTAssertEqual(record.outcomes[graph.toolA], .fromCache, "the record is the latest settle's")
        XCTAssertEqual(record.outcomes[graph.toolB], .computed)
        XCTAssertEqual(record.wakes[graph.toolA]?.map(\.change), [.unchanged])
    }

    /// The loop passes through idle on every signal; one with no work behind it is not the
    /// settle anyone is asking about.
    func test_aSettleThatScheduledNothingKeepsTheRecord() async throws {
        _ = try await buildGraph()
        let before = try record

        await settle()

        XCTAssertEqual(try record, before)
    }

    // MARK: - The explanation

    private func explanation(of nodeID: ObjectID, nodeLimit: Int = SettleExplanation.nodeLimit,
                             depthLimit: Int = SettleExplanation.depthLimit) throws -> SettleExplanation {
        SettleExplanation(explaining: nodeID, record: try record, database: engine.database,
                          nodeLimit: nodeLimit, depthLimit: depthLimit, causeLimit: SettleExplanation.causeLimit)
    }

    /// Upstream through the wires that changed, to the file the push changed.
    func test_anExplanationWalksUpTheChangedWiresToTheSource() async throws {
        let graph = try await buildGraph()
        try push("a.x=2\nb.y=1\n")
        await settle()

        let explained = try explanation(of: graph.toolA)

        XCTAssertEqual(explained.entries.map(\.nodeID), [graph.toolA, graph.filterA, graph.file])
        XCTAssertEqual(explained.entries.map(\.state), [.computed, .computed, .changed])
        XCTAssertEqual(explained.entries[0].causes.map(\.sourceIndex), [1])
        XCTAssertEqual(explained.entries[1].causes.map(\.port), ["input"])
        XCTAssertEqual(explained.entries[1].causes.map(\.wire), ["config"])
        XCTAssertEqual(explained.entries[1].causes.map(\.sourceIndex), [2])
        XCTAssertTrue(explained.entries[2].label.hasPrefix("StaticFile #"), explained.entries[2].label)
        XCTAssertTrue(explained.entries[2].label.hasSuffix("'\(configPath)'"), explained.entries[2].label)
        XCTAssertEqual(explained.omittedNodes, 0)
    }

    /// The cache answered the tool, and nothing new reached it: the wire that woke it is
    /// named and the walk stops there. (From a node that ran, the walk goes on up such a
    /// wire — `ExplainRequestTests` holds it to that with a product, which always runs.)
    func test_anUnchangedWireIntoANodeTheCacheAnsweredIsNamedAndNotFollowed() async throws {
        let graph = try await buildGraph()
        try push("a.x=2\nb.y=1\n")
        await settle()

        let explained = try explanation(of: graph.toolB)

        XCTAssertEqual(explained.entries.map(\.state), [.fromCache])
        XCTAssertEqual(explained.entries[0].causes.map(\.change), [.unchanged])
        XCTAssertEqual(explained.entries[0].causes.map(\.sourceIndex), [nil])
        XCTAssertEqual(explained.entries[0].causes.first?.sourceNodeID, graph.filterB)
        XCTAssertEqual(explained.omittedNodes, 0)
    }

    /// A new node wired to one the settle did not touch: the wire is why it ran, and the
    /// node behind it has nothing to add, so it is named and not walked into.
    func test_aWireConnectedToAnUntouchedNodeIsNamedAndNotFollowed() async throws {
        let graph = try await buildGraph()
        let toolC = try nodeID("SampleTool(configuration: ['other': \(filterSpec("a"))]).output")
        await settle()

        let explained = try explanation(of: toolC)

        XCTAssertEqual(try record.outcomes[graph.filterA], nil, "precondition: the filter did not run")
        XCTAssertEqual(explained.entries.map(\.state), [.computed])
        XCTAssertTrue(explained.entries[0].isNew)
        XCTAssertEqual(explained.entries[0].causes.map(\.change), [.connected])
        XCTAssertEqual(explained.entries[0].causes.map(\.sourceIndex), [nil])
        XCTAssertEqual(explained.omittedNodes, 0)
    }

    func test_aNodeTheSettleNeverReachedIsUntouched() async throws {
        _ = try await buildGraph()
        let bystander = try nodeID("SettingsLiteral(role: 'bystander').output")

        let explained = try explanation(of: bystander)

        XCTAssertEqual(explained.entries.map(\.state), [.untouched])
        XCTAssertEqual(explained.entries[0].causes, [])
    }

    /// Stopped by a bound, the answer says how many it left out.
    func test_theWalkStopsAtItsBoundsAndCountsWhatItLeftOut() async throws {
        let graph = try await buildGraph()
        try push("a.x=2\nb.y=1\n")
        await settle()

        let byCount = try explanation(of: graph.toolA, nodeLimit: 2)
        XCTAssertEqual(byCount.entries.map(\.nodeID), [graph.toolA, graph.filterA])
        XCTAssertEqual(byCount.entries[1].causes.map(\.sourceIndex), [nil])
        XCTAssertEqual(byCount.omittedNodes, 1)
        XCTAssertEqual(byCount.nodeLimit, 2)

        let byDepth = try explanation(of: graph.toolA, depthLimit: 1)
        XCTAssertEqual(byDepth.entries.map(\.nodeID), [graph.toolA, graph.filterA])
        XCTAssertEqual(byDepth.omittedNodes, 1)
        XCTAssertEqual(byDepth.depthLimit, 1)
    }

    /// Wakes on one wire fold into one cause, the strongest change it brought, and the
    /// causes come out in one order however they were collected.
    func test_wakesOnOneWireFoldIntoTheStrongestChange() {
        func wake(_ fromNodeID: ObjectID, _ change: SettleRecord.Change) -> SettleRecord.Wake {
            SettleRecord.Wake(fromNodeID: fromNodeID, fromPortSymbolID: 1, toPortSymbolID: 2,
                              wireNameSymbolID: 3, change: change)
        }

        let folded = SettleRecord.deduplicated([wake(7, .unchanged), wake(9, .unchanged),
                                                wake(7, .connected), wake(7, .changed)])

        XCTAssertEqual(folded, [wake(7, .changed), wake(9, .unchanged)])
    }
}
