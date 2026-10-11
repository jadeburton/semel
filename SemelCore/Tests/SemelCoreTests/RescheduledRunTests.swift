//
//  RescheduledRunTests.swift
//  SemelCoreTests
//
//  B-151. A node is taken off the schedule as it starts and reads its inputs a moment
//  later. An input written in that moment schedules it again, and its run reads the new
//  value all the same: it has answered what it was scheduled for, and does not run again.
//  A real processing loop, with the node held between its start and its read.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class RescheduledRunTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try TypeRegistry.register(types: [StartGatedSampleTool.self, FollowingSampleTool.self])
        StartGatedSampleTool.gate.open()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.startProcessingLoop()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        // Open, so that a run a failed test left waiting can finish and the loop can stop.
        StartGatedSampleTool.gate.open()
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        super.tearDown()
    }

    /// Pushes in a batch of its own, as a request does.
    private func push(_ contents: String) throws {
        engine.beginBatch()
        defer { engine.endBatch() }
        _ = try StaticFile.push(Array(contents.utf8), mode: FileMetadata.defaultMode, at: Path("src/read.txt"))
    }

    func test_aNodeWhoseRunReadTheWriteThatRescheduledItDoesNotRunAgain() async throws {
        try push("one")
        engine.beginBatch()
        let nodeID = try GraphSpecNode.parse("StartGatedSampleTool(input: ['read': StaticFile(path: 'input:/src/read.txt').output]).output")
            .findOrCreateMatchingNode().fromNode.requireID()
        engine.endBatch()
        await engine.waitUntilIdle()
        let runsBefore = StartGatedSampleTool.runs.value

        // Started, and held before it reads.
        StartGatedSampleTool.gate.close()
        try push("two")
        XCTAssertTrue(StartGatedSampleTool.gate.waitForArrival(timeout: 60), "precondition: the node has started")

        // Written while it is held: it is scheduled again, and reads this when let go.
        try push("three")
        let scheduled = try XCTUnwrap(try engine.database.node.find(nodeID: nodeID)).scheduled
        XCTAssertTrue(scheduled, "precondition: the write scheduled the running node again")
        StartGatedSampleTool.gate.open()
        await engine.waitUntilIdle()

        XCTAssertEqual(StartGatedSampleTool.runs.value - runsBefore, 1, "one run, over what it read")
        XCTAssertEqual(StartGatedSampleTool.lastRead.value, "three")
        let record = try XCTUnwrap(engine.lastSettleRecord)
        XCTAssertEqual(record.outcomes[nodeID], .computed, "the settle computed it, and nothing answered it again")
    }

    /// The node's own demands still run it again: the wire its write adds is an input it
    /// did not read.
    func test_aNodeRunsAgainOverTheWireItsOwnWriteAdded() async throws {
        engine.beginBatch()
        _ = try StaticFile.push(Array("followed".utf8), mode: FileMetadata.defaultMode, at: Path("src/followed.txt"))
        engine.endBatch()
        try push("input:/src/followed.txt")
        engine.beginBatch()
        let nodeID = try GraphSpecNode.parse("FollowingSampleTool(input: ['read': StaticFile(path: 'input:/src/read.txt').output]).output")
            .findOrCreateMatchingNode().fromNode.requireID()
        engine.endBatch()
        await engine.waitUntilIdle()

        let output = try XCTUnwrap(try engine.database.node.find(nodeID: nodeID))
            .readFromOutputPort(FollowingSampleTool.output)
        guard case .value(let hash) = output else {
            return XCTFail("the node has a value: \(String(describing: output))")
        }
        XCTAssertEqual(try hash.resolveAsString(), "followed", "the second run read the wire the first demanded")
    }
}

/// A node that reads a path on its input and demands the file there on a port of its own,
/// publishing what that file holds once it has it — nothing, on the run before.
struct FollowingSampleTool: Node {
    static let kind: UInt = 987_144

    static let input    = "input"
    static let followed = "followed"
    static let output   = "output"

    var thisNode: NodeRecord

    init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    static let descriptor = NodeDescriptor(inputPorts: [.required(input), .dynamic(followed)], outputPorts: [output])

    func process(input: ProcessInput) throws -> ProcessOutput {
        let path     = try input.onlyWire(onRequiredPort: Self.input).value.expectValue().resolveAsString()
        let followed = try input.wires(on: Self.followed).values.map { try $0.expectValue().resolveAsString() }
        return .init(outputValues: [Self.output: .value(try followed.joined().intern())],
                     inputWireSpecs: [Self.followed: ["file": GraphSpecNode.staticFile(at: path)]])
    }
}

/// A node that waits at its gate as it is made on a compute thread — after the loop has
/// taken it off the schedule and before it reads its inputs — and counts its runs.
struct StartGatedSampleTool: Node {
    static let kind: UInt = 987_143

    static let input  = "input"
    static let output = "output"

    static let gate     = PassGate()
    static let runs     = SharedCounter()
    static let lastRead = LockedText()

    var thisNode: NodeRecord

    init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
        // The thread `BuildEngine.compute` makes: the loop and the write path make this
        // node too, and must not be held.
        if Thread.current.name == "semel.compute" {
            Self.gate.arriveAndWait()
        }
    }

    static let descriptor = NodeDescriptor(inputPorts: [.required(input, .many)], outputPorts: [output])

    func process(input: ProcessInput) throws -> ProcessOutput {
        Self.runs.increment()
        let wires = (input.inputValues[Self.input] ?? [:]).sorted { $0.key < $1.key }
        let text  = try wires.map { try $0.value.expectValue().resolveAsString() }.joined(separator: "\n")
        Self.lastRead.value = text
        return .init(outputValues: [Self.output: .value(try text.intern())], inputWireSpecs: [:])
    }
}

/// A string written on one thread and read on another.
final class LockedText {
    private let lock = NSLock()
    private var storage = ""

    var value: String {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
