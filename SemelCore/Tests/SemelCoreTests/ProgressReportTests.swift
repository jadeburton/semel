//
//  ProgressReportTests.swift
//  SemelCore
//
//  B-95. The progress report is the settle tally read mid-settle, so these hold it to the
//  tally's promises — each node once, the totals the summary ends with — and to the two
//  moments it is sent. They run a real processing loop on `TimedNode`, as
//  ConcurrencyTests does, because progress is a thing a pass has.
//

@testable import SemelCore
import SemelNodeKit
import XCTest

final class ProgressReportTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private let log = ReportLog()

    /// What the two reporters were handed, in the order they were called. Written from
    /// the loop's task and read from the test's thread, so it has a lock of its own.
    private final class ReportLog {
        enum Entry: Equatable {
            case progress(ProgressReport)
            case settled(SettleSummary)
        }

        private let lock = NSLock()
        private var storage: [Entry] = []

        func append(_ entry: Entry) {
            lock.withLock { storage.append(entry) }
        }

        var all: [Entry] {
            lock.withLock { storage }
        }

        var progress: [ProgressReport] {
            all.compactMap {
                if case .progress(let report) = $0 { return report }
                return nil
            }
        }

        func clear() {
            lock.withLock { storage = [] }
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try TypeRegistry.register(types: [TimedNode.self])
        TimedNode.finished.clear()
        TimedNode.running.reset()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: true, jobs: 2)
        BuildEngine.shared = engine
        engine.progressReporter = { [log] report in log.append(.progress(report)) }
        engine.settleReporter   = { [log] summary in log.append(.settled(summary)) }
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    /// `count` independent nodes of `seconds` each, published in one batch once their
    /// inputs have settled, so one pass runs them all.
    private func publishTimedNodes(count: Int, seconds: Double) async throws {
        let inputs = (0..<count).map { "SettingsLiteral(role: 'in\($0)').output" }
        for input in inputs {
            _ = try GraphSpecNode.parse(input).findOrCreateMatchingNode()
        }
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()
        log.clear()

        engine.beginBatch()
        for (index, input) in inputs.enumerated() {
            _ = try GraphSpecNode.parse("TimedNode(label: 'n\(index)', seconds: '\(seconds)', input: ['in': \(input)]).output")
                .findOrCreateMatchingNode()
        }
        engine.signalWorkAvailable()
        engine.endBatch()
    }

    /// Four nodes, two jobs: reports as the pass starts and finishes them, never naming
    /// more running than jobs, never counting a node twice, ending drained just before
    /// the summary that carries the same totals.
    func test_reportsFollowThePassAndEndWhereTheSummaryBegins() async throws {
        try await publishTimedNodes(count: 4, seconds: 0.2)
        await engine.waitUntilIdle()

        let entries  = log.all
        let progress = log.progress
        XCTAssertFalse(progress.isEmpty, "a pass that started nodes reported")

        for report in progress {
            XCTAssertLessThanOrEqual(report.running.count, 2, "never more running than jobs")
            XCTAssertLessThanOrEqual(report.scheduled, 4, "each node once, however many rounds fetched it")
        }
        for (earlier, later) in zip(progress, progress.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.scheduled, later.scheduled, "the tally only grows within a settle")
        }

        let first = try XCTUnwrap(progress.first)
        XCTAssertEqual(first.running.count, 2, "the first report is the first round's starts")
        XCTAssertEqual(first.pending, 2, "with the other two still ahead")
        XCTAssertEqual(first.running.first?.typeName, "TimedNode")

        let last = try XCTUnwrap(progress.last)
        XCTAssertTrue(last.running.isEmpty, "the last report has nothing running")
        XCTAssertEqual(last.pending, 0, "and nothing ahead")

        guard case .settled(let summary)? = entries.last else {
            return XCTFail("the summary follows the last report, got \(String(describing: entries.last))")
        }
        XCTAssertEqual(last.scheduled, summary.scheduled)
        XCTAssertEqual(last.computed,  summary.computed)
        XCTAssertEqual(last.fromCache, summary.fromCache)
        XCTAssertEqual(summary.computed, 4)
    }

    /// A pass with nothing to start says nothing, as the summary says nothing for a settle
    /// that scheduled nothing: the loop passes through idle on every signal, and a report
    /// per pass would be a line per signal.
    func test_aPassThatStartsNothingReportsNothing() async throws {
        await engine.waitUntilIdle()
        log.clear()

        engine.signalWorkAvailable()
        await engine.waitUntilIdle()

        XCTAssertEqual(log.progress, [])
    }

    /// A node with no path of its own is named by the file on its `input` port, as a
    /// compiler is by the source it compiles; a wire named anything else names nothing.
    func test_aNodeWithNoPathIsNamedByItsInputFile() async throws {
        let input = "SettingsLiteral(role: 'source').output"
        _ = try GraphSpecNode.parse(input).findOrCreateMatchingNode()
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()
        log.clear()

        engine.beginBatch()
        _ = try GraphSpecNode.parse("TimedNode(label: 'named', seconds: '0.05', input: ['input:/src/a.c': \(input)]).output")
            .findOrCreateMatchingNode()
        _ = try GraphSpecNode.parse("TimedNode(label: 'unnamed', seconds: '0.05', input: ['in': \(input)]).output")
            .findOrCreateMatchingNode()
        engine.signalWorkAvailable()
        engine.endBatch()
        await engine.waitUntilIdle()

        let names = Set(log.progress.flatMap(\.running).map(\.name))
        XCTAssertEqual(names, ["input:/src/a.c", ""])
    }
}
