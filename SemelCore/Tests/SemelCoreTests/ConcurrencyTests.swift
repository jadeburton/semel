//
//  ConcurrencyTests.swift
//  SemelCore
//
//  B-114. How many nodes compute at once is a setting, `jobs`, and the computing happens
//  off the cooperative pool: a tool's `process()` is a wait on a child process, and the
//  pool — one thread per core — carries the loop's signals and every client's wait.
//  These run a real processing loop, as SchedulingTests does, on its TimedNode.
//

@testable import SemelCore
import SemelNodeKit
import XCTest

final class ConcurrencyTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try TypeRegistry.register(types: [TimedNode.self])
        TimedNode.finished.clear()
        TimedNode.running.reset()
    }

    override func tearDown() {
        // A loop left running would keep processing against the next test's globals.
        engine?.stopProcessingLoop()
        engine?.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    private func start(jobs: Int) throws {
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: true, jobs: jobs)
        BuildEngine.shared = engine
    }

    /// `count` independent nodes of `seconds` each. Their inputs settle first, so each
    /// runs once, on a value, and the loop is asked for the pass that runs them.
    private func publishTimedNodes(count: Int, seconds: Double) async throws {
        let inputs = (0..<count).map { "Configuration(role: 'in\($0)').output" }
        for input in inputs {
            _ = try GraphSpecNode.parse(input).findOrCreateMatchingNode()
        }
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()

        // In one batch, so the loop is asked once, with every node in place: a pass that
        // starts before the last node exists picks the rest up only as a running one ends.
        engine.beginBatch()
        for (index, input) in inputs.enumerated() {
            _ = try GraphSpecNode.parse("TimedNode(label: 'n\(index)', seconds: '\(seconds)', input: ['in': \(input)]).output")
                .findOrCreateMatchingNode()
        }
        engine.signalWorkAvailable()
        engine.endBatch()
    }

    /// Four nodes ready at once and two jobs: two run at a time, never three, and not one.
    func test_jobsIsHowManyNodesComputeAtOnce() async throws {
        try start(jobs: 2)
        try await publishTimedNodes(count: 4, seconds: 0.3)

        await engine.waitUntilIdle()

        XCTAssertEqual(TimedNode.running.peak, 2)
        XCTAssertEqual((0..<4).compactMap { TimedNode.finished["n\($0)"] }.count, 4, "every node ran")
    }

    /// B-117. A node scheduled while another runs starts as soon as a slot is free, not
    /// when the running one finishes: the pass waits on the next result or the next
    /// signal, whichever comes first. Before, the fast node here waited the slow one out.
    func test_aNodeScheduledDuringAPassStartsWhileASlotIsFree() async throws {
        try start(jobs: 2)
        try await publishTimedNodes(count: 1, seconds: 2)
        let deadline = Date().addingTimeInterval(5)
        while TimedNode.running.current < 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(TimedNode.running.current, 1, "precondition: the slow node is running")

        let fastInput = "Configuration(role: 'fast-in').output"
        engine.beginBatch()
        _ = try GraphSpecNode.parse(fastInput).findOrCreateMatchingNode()
        _ = try GraphSpecNode.parse("TimedNode(label: 'fast', seconds: '0', input: ['in': \(fastInput)]).output")
            .findOrCreateMatchingNode()
        engine.signalWorkAvailable()
        let published = Date()
        engine.endBatch()

        await engine.waitUntilIdle()

        let fastDone = try XCTUnwrap(TimedNode.finished["fast"])
        let slowDone = try XCTUnwrap(TimedNode.finished["n0"])
        XCTAssertLessThan(fastDone, slowDone, "the fast node did not wait for the slow one")
        XCTAssertLessThan(fastDone.timeIntervalSince(published), 1, "the fast node started as soon as it was scheduled")
    }

    /// As many blocking nodes as the pool has threads, all running — and a task put on the
    /// pool still runs at once, because the nodes are not on it. Before B-114 that task
    /// waited for the first node to finish.
    func test_theCooperativePoolIsFreeWhileEveryJobIsBusy() async throws {
        let jobs = MachineQuery.activeProcessorCount
        try start(jobs: jobs)
        try await publishTimedNodes(count: jobs, seconds: 1)

        let deadline = Date().addingTimeInterval(5)
        while TimedNode.running.current < jobs, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let inside = TimedNode.running.current

        let asked = Date()
        await Task.detached { }.value
        let waited = Date().timeIntervalSince(asked)
        await engine.waitUntilIdle()

        XCTAssertEqual(inside, jobs, "precondition: every job is inside a node (peak \(TimedNode.running.peak))")
        XCTAssertEqual(TimedNode.running.peak, jobs, "fewer nodes ran at once than jobs")
        XCTAssertLessThan(waited, 0.5, "a task on the pool waited \(waited) s behind the running nodes")
    }
}
