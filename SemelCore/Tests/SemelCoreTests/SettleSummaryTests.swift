//
//  SettleSummaryTests.swift
//  SemelCore
//
//  B-81. The summary exists to tell a node that ran from one the cache answered, so these
//  hold it to that distinction on a real cache hit rather than on a stub. They run a real
//  processing loop, as SettleTests does, because the totals are accumulated across a
//  settle and read where the loop reaches idle.
//

@testable import SemelCore
import SemelNodeKit
import XCTest

final class SettleSummaryTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private let summaries = SummaryLog()

    /// Captures what the reporter was handed. The reporter is called from the loop's task
    /// and read from the test's thread, so the captures need a lock of their own.
    private final class SummaryLog {
        private let lock = NSLock()
        private var storage: [SettleSummary] = []

        func append(_ summary: SettleSummary) {
            lock.withLock { storage.append(summary) }
        }

        var all: [SettleSummary] {
            lock.withLock { storage }
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: true)
        BuildEngine.shared = engine
        engine.settleReporter = { [summaries] summary in summaries.append(summary) }
        // Above the cache's floor, so the tool's result is stored and the second build has
        // something to hit.
        SampleTool.processingDurationForTests = 0.02
    }

    override func tearDown() {
        SampleTool.processingDurationForTests = 0
        // A loop left running would keep processing against the next test's globals.
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    /// A `SampleTool` fed by one configuration node: the smallest graph with something
    /// cacheable in it. `SampleTool.process` interns a result, and its `configuration`
    /// port is static, which is what makes it a node the cache answers for.
    private func makeToolWiredToAConfiguration() throws -> NodeRecord {
        let spec = "SampleTool(configuration: ['cfg': Configuration(role: 'settle-summary').output])"
        let (node, _) = try GraphSpecNode.parse(spec).findOrCreateMatchingNode()
        return node
    }

    func test_aNodeThatRanIsCountedAsComputedAndNotAsACacheHit() async throws {
        await engine.waitUntilIdle()

        _ = try makeToolWiredToAConfiguration()
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()

        let summary = try XCTUnwrap(summaries.all.last)
        XCTAssertGreaterThan(summary.computed, 0, "the tool ran")
        XCTAssertEqual(summary.fromCache, 0, "and nothing in a graph built for the first time can hit")
        XCTAssertEqual(summary.errors, 0)
    }

    /// The same graph built a second time. Rescheduling the node is what a cascade does
    /// when a wire wakes; its inputs are unchanged, so its key is unchanged, so the cache
    /// answers and nothing runs. A node processed on that pass belongs under `fromCache`
    /// and nowhere else, which is the whole distinction the summary carries.
    func test_aSecondBuildOfTheSameGraphComputesNothingAndComesFromTheCache() async throws {
        let tool = try makeToolWiredToAConfiguration()
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()
        XCTAssertGreaterThan(try XCTUnwrap(summaries.all.last).computed, 0,
                             "precondition: the first build ran the tool")

        try engine.database.node.select(nodeID: try tool.requireID()).setScheduled(true)
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()

        let summary = try XCTUnwrap(summaries.all.last)
        XCTAssertEqual(summary.computed, 0, "nothing ran the second time")
        XCTAssertEqual(summary.fromCache, 1, "the tool was answered out of the cache")
        XCTAssertEqual(summary.scheduled, 1)
    }

    /// The loop passes through idle whenever a signal turns out to have had no work behind
    /// it; a summary for each of those would bury the ones that mean something.
    func test_aSettleThatScheduledNothingReportsNothing() async throws {
        await engine.waitUntilIdle()
        let before = summaries.all.count

        engine.signalWorkAvailable()
        await engine.waitUntilIdle()

        XCTAssertEqual(summaries.all.count, before, "an empty pass says nothing")
    }
}
