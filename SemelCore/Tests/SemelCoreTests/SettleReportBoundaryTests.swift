//
//  SettleReportBoundaryTests.swift
//  SemelCoreTests
//
//  B-151. A settle is reported over a graph its passes have processed, and over a batch
//  only once it is whole: a removal and the push that puts the file back, in one batch,
//  report nothing in between. A real processing loop, held in a pass by a node that waits
//  for the test, so that the batch's first half lands while the pass is under way.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class SettleReportBoundaryTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private let reports = Reports()

    /// What the loop said, captured on its task and read on the test's; `onReport` is
    /// told of each report as it is made.
    private final class Reports {
        private let lock = NSLock()
        private var errorBatches: [[ErrorReport.Entry]] = []
        private var summaries: [SettleSummary] = []
        private var reportObserver: (() -> Void)?

        func append(errors entries: [ErrorReport.Entry]) {
            let observer = lock.withLock { () -> (() -> Void)? in
                errorBatches.append(entries)
                return reportObserver
            }
            observer?()
        }

        func append(summary: SettleSummary) {
            let observer = lock.withLock { () -> (() -> Void)? in
                summaries.append(summary)
                return reportObserver
            }
            observer?()
        }

        func observe(_ observer: (() -> Void)?) {
            lock.withLock { reportObserver = observer }
        }

        func forget() {
            lock.withLock {
                errorBatches = []
                summaries = []
            }
        }

        var errors: [[ErrorReport.Entry]] {
            lock.withLock { errorBatches }
        }

        var settles: [SettleSummary] {
            lock.withLock { summaries }
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try TypeRegistry.register(types: [GatedSampleTool.self])
        GatedSampleTool.gate.open()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.errorReporter  = { [reports] entries in reports.append(errors: entries) }
        engine.settleReporter = { [reports] summary in reports.append(summary: summary) }
        engine.startProcessingLoop()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        // Open, so that a pass a failed test left waiting can finish and the loop can stop.
        GatedSampleTool.gate.open()
        reports.observe(nil)
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    private func push(_ relativePath: String, _ contents: String) throws {
        _ = try StaticFile.push(Array(contents.utf8), mode: FileMetadata.defaultMode, at: Path(relativePath))
    }

    /// Suspends until the loop reports a settle or marks itself idle, whichever is first.
    private func reportOrIdle() async {
        let reached = expectation(description: "a report or the idle mark")
        reached.assertForOverFulfill = false
        reports.observe { reached.fulfill() }
        let idle = Task { [engine] in
            await engine?.waitUntilIdle()
            reached.fulfill()
        }
        await fulfillment(of: [reached], timeout: 60)
        reports.observe(nil)
        idle.cancel()
    }

    /// The removal of a file a node reads, and the push that puts it back, in one batch,
    /// with a pass under way when the removal lands. The pass reaches its end with the
    /// batch half done, and what it would report there — the file removed, its reader in
    /// error — is not a state the batch ever stands in. The settle is reported once the
    /// batch has ended, and the file is there.
    func test_aBatchStillOpenWhenAPassEndsIsReportedOnlyOnceItHasEnded() async throws {
        engine.beginBatch()
        try push("src/read.txt", "read")
        try push("src/held.txt", "first")
        _ = try GraphSpecNode.parse("DemandingSampleTool(input: ['read': StaticFile(path: 'input:/src/read.txt').output]).output")
            .findOrCreateMatchingNode()
        _ = try GraphSpecNode.parse("GatedSampleTool(input: ['held': StaticFile(path: 'input:/src/held.txt').output]).output")
            .findOrCreateMatchingNode()
        engine.signalWorkAvailable()
        engine.endBatch()
        await engine.waitUntilIdle()
        XCTAssertEqual(reports.errors.count, 0, "precondition: the graph builds")
        reports.forget()

        // A pass, held open by the gated node.
        GatedSampleTool.gate.close()
        engine.beginBatch()
        try push("src/held.txt", "second")
        engine.endBatch()
        let arrived = GatedSampleTool.gate.waitForArrival(timeout: 60)
        XCTAssertTrue(arrived, "precondition: the pass is under way")

        // The batch's first half lands while the pass runs, and the pass ends with it open.
        engine.beginBatch()
        let file      = try XCTUnwrap(try engine.inputFileSystem.childNode(path: Path("src/read.txt")))
        let deletable = try XCTUnwrap(try file.nodeAsAny() as? UserDeletable)
        try deletable.deleteInInputFileSystem()
        GatedSampleTool.gate.open()
        await reportOrIdle()

        try push("src/read.txt", "read")
        engine.endBatch()
        await engine.waitUntilIdle()

        XCTAssertEqual(reports.errors.count, 0,
                       "nothing was reported over the half of the batch: \(reports.errors)")
        XCTAssertEqual(reports.settles.count, 1, "one settle, reported once: \(reports.settles)")
        XCTAssertEqual(reports.settles.last?.errors, 0)
    }
}

/// A node that waits, in its run, until the test opens its gate: what holds a pass open
/// while a test writes to the graph beside it.
struct GatedSampleTool: Node {
    static let kind: UInt = 987_142

    static let input  = "input"
    static let output = "output"

    static let gate = PassGate()

    var thisNode: NodeRecord

    init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    static let descriptor = NodeDescriptor(inputPorts: [.required(input, .many)], outputPorts: [output],
                                           cachesOutputs: false)

    func process(input: ProcessInput) throws -> ProcessOutput {
        Self.gate.arriveAndWait()
        let wires = (input.inputValues[Self.input] ?? [:]).sorted { $0.key < $1.key }
        let text  = try wires.map { try $0.value.expectValue().resolveAsString() }.joined(separator: "\n")
        return .init(outputValues: [Self.output: .value(try text.intern())], inputWireSpecs: [:])
    }
}

/// Open or closed; a run arriving at a closed gate is counted and waits for it to open. A
/// wait is bounded, so a test that never opens it fails rather than hangs.
final class PassGate {
    private let condition = NSCondition()
    private var isOpen = true
    private var arrivals = 0

    func close() {
        condition.withLock {
            isOpen   = false
            arrivals = 0
        }
    }

    func open() {
        condition.withLock {
            isOpen = true
            condition.broadcast()
        }
    }

    func arriveAndWait() {
        condition.withLock {
            arrivals += 1
            condition.broadcast()
            let deadline = Date(timeIntervalSinceNow: 60)
            while !isOpen, condition.wait(until: deadline) {
            }
        }
    }

    /// Whether a run arrived at the closed gate within `timeout` seconds.
    func waitForArrival(timeout: TimeInterval) -> Bool {
        condition.withLock {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while arrivals == 0 {
                guard condition.wait(until: deadline) else {
                    return false
                }
            }
            return true
        }
    }
}
