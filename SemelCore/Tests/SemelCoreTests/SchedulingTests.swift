//
//  SchedulingTests.swift
//  SemelCore
//
//  B-113. A result is written as soon as its node finishes, and writing it is what
//  schedules its consumers; so a consumer of a fast node runs while a slow node that
//  started beside it is still running. These run a real processing loop, as SettleTests
//  does, because the order is the loop's.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class SchedulingTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try TypeRegistry.register(types: [TimedNode.self])
        TimedNode.finished.clear()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.startProcessingLoop()
    }

    override func tearDown() {
        // A loop left running would keep processing against the next test's globals.
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    private func timed(_ label: String, seconds: Double, input: String) -> String {
        "TimedNode(label: '\(label)', seconds: '\(seconds)', input: ['in': \(input)]).output"
    }

    func test_aFastNodesConsumerDoesNotWaitForASlowNodeStartedBesideIt() async throws {
        // The inputs settle first, so the slow node runs once, on a value.
        let slowInput = "SettingsLiteral(role: 'slow').output"
        let fastInput = "SettingsLiteral(role: 'fast').output"
        _ = try GraphSpecNode.parse(slowInput).findOrCreateMatchingNode()
        _ = try GraphSpecNode.parse(fastInput).findOrCreateMatchingNode()
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()

        let slow     = timed("slow", seconds: 1, input: slowInput)
        let fast     = timed("fast", seconds: 0, input: fastInput)
        let consumer = timed("consumer", seconds: 0, input: fast)
        _ = try GraphSpecNode.parse(slow).findOrCreateMatchingNode()
        _ = try GraphSpecNode.parse(consumer).findOrCreateMatchingNode()
        engine.signalWorkAvailable()
        await engine.waitUntilIdle()

        let slowDone     = try XCTUnwrap(TimedNode.finished["slow"])
        let consumerDone = try XCTUnwrap(TimedNode.finished["consumer"])
        XCTAssertLessThan(consumerDone, slowDone,
                          "the consumer ran only once the slow node had finished: a batch barrier")
    }
}

/// A node that takes as long as its `seconds` property says and records, under its `label`,
/// when it first finished a run on a real input value. A run on an input that has no value
/// yet — a consumer created beside its provider — records nothing.
struct TimedNode: Node {
    static let kind: UInt = 987_120

    static let input  = "input"
    static let output = "output"

    var thisNode: NodeRecord

    init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    static let descriptor = NodeDescriptor(inputPorts: [.required(input)], outputPorts: [output])

    /// When each label finished. Written from the loop's tasks and read from the test.
    final class FinishLog {
        private let lock = NSLock()
        private var times: [String: Date] = [:]

        subscript(label: String) -> Date? {
            lock.withLock { times[label] }
        }

        func record(_ label: String) {
            lock.withLock {
                if times[label] == nil {
                    times[label] = Date()
                }
            }
        }

        func clear() {
            lock.withLock { times = [:] }
        }
    }

    static let finished = FinishLog()

    /// How many runs are inside `process()` now, and the most there have been at once
    /// (B-114). Written from the compute threads and read from the test.
    final class Gauge {
        private let lock = NSLock()
        private var inside = 0
        private var most = 0

        var current: Int { lock.withLock { inside } }
        var peak: Int { lock.withLock { most } }

        func enter() {
            lock.withLock {
                inside += 1
                most = max(most, inside)
            }
        }

        func leave() {
            lock.withLock { inside -= 1 }
        }

        func reset() {
            lock.withLock {
                inside = 0
                most = 0
            }
        }
    }

    static let running = Gauge()

    func process(input: ProcessInput) throws -> ProcessOutput {
        let label = thisNode.properties["label"] ?? ""
        guard (try? input.inputValues[Self.input]?.values.first?.expectValue()) != nil else {
            return .init(outputValues: [Self.output: .noValue(reason: .inputNotProduced)], inputWireSpecs: [:])
        }
        Self.running.enter()
        Thread.sleep(forTimeInterval: Double(thisNode.properties["seconds"] ?? "0") ?? 0)
        Self.running.leave()
        Self.finished.record(label)
        return .init(outputValues: [Self.output: .value(try label.intern())], inputWireSpecs: [:])
    }
}
