//
//  WaitEventsTests.swift
//  SemelServerTests
//
//  B-95. A `wait` blocks until the graph settles, and the events the same client reads
//  meanwhile — progress above all — have to reach it *while* it waits. They did not: the
//  handler parked the connection's queue on the wait, and every event to that client
//  leaves through that queue, so they arrived in one burst as the wait returned. This runs
//  a real loop behind a real socket, with a node slow enough to be caught running.
//

@testable import SemelCLI
@testable import SemelCore
@testable import SemelServer
import SemelNodeKit
import SemelProtocol
import XCTest

final class WaitEventsTests: XCTestCase {

    private var directory: URL!
    private var engine: BuildEngine!
    private var handler: RequestHandler!
    private var server: Server!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: a Unix-domain socket path is limited to 103 bytes on macOS.
        directory = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        DataObjectStore.shared = DataObjectStore(storeRoot: directory.appendingPathComponent("store", isDirectory: true))
        try TypeRegistry.register(types: [SlowNode.self])

        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.startProcessingLoop()
        handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        server  = Server(handler: handler, socketPath: directory.appendingPathComponent("semelserv.sock").path)
        try server.start()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        server.stop()
        server = nil
        engine.stopProcessingLoop()
        engine.waitUntilIdleBlocking()
        engine = nil
        BuildEngine.shared = nil
        handler = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    /// Every event the client received, with when it arrived. Written on the connection's
    /// reader queue and read from the test's thread.
    private final class ArrivalLog {
        private let lock = NSLock()
        private var storage: [(event: Event, at: Date)] = []

        func record(_ event: Event) {
            lock.withLock { storage.append((event, Date())) }
        }

        var all: [(event: Event, at: Date)] {
            lock.withLock { storage }
        }
    }

    /// A progress event with the slow node running arrives well before the wait returns,
    /// not with it: the wait spans the node's whole run, and the first sighting of the
    /// node running is early in that span.
    func test_progressReachesTheClientWhileItsWaitIsStillBlocked() throws {
        let client = try SocketConnection.connect(to: directory.appendingPathComponent("semelserv.sock").path)
        let arrivals = ArrivalLog()
        client.onEvent = { arrivals.record($0) }
        _ = try client.send(.hello(Hello(role: .daemon)), body: nil)
        _ = try client.send(.daemon(.subscribe), body: nil)

        // The input first, settled, so the slow node's one run is on a value.
        _ = try GraphSpecNode.parse("SettingsLiteral(role: 'slow-in').output").findOrCreateMatchingNode()
        engine.signalWorkAvailable()
        engine.waitUntilIdleBlocking()

        engine.beginBatch()
        _ = try GraphSpecNode.parse("SlowNode(input: ['in': SettingsLiteral(role: 'slow-in').output]).output")
            .findOrCreateMatchingNode()
        engine.signalWorkAvailable()
        engine.endBatch()

        let waitBegan = Date()
        _ = try client.send(.daemon(.wait), body: nil)
        let waitReturned = Date()

        XCTAssertGreaterThanOrEqual(waitReturned.timeIntervalSince(waitBegan), SlowNode.seconds - 0.2,
                                    "precondition: the wait spanned the slow node's run")

        let firstSighting = arrivals.all.first { entry in
            guard case .daemon(.progress(let record)) = entry.event else {
                return false
            }
            return record.running.contains { $0.type == "SlowNode" }
        }
        let sighting = try XCTUnwrap(firstSighting, "no progress event named the slow node as running; got \(arrivals.all.map(\.event))")
        XCTAssertLessThan(sighting.at.timeIntervalSince(waitBegan), SlowNode.seconds / 2,
                          "the event was held back until the wait returned")
    }
}

/// A node that takes `seconds` to run, so a wait on it is long enough to be observed.
private struct SlowNode: Node {
    static let kind: UInt = 987_130
    static let seconds: TimeInterval = 1.5

    static let input  = "input"
    static let output = "output"

    var thisNode: NodeRecord

    init(thisNode: NodeRecord) throws {
        self.thisNode = thisNode
    }

    static let descriptor = NodeDescriptor(inputPorts: [.required(input)], outputPorts: [output])

    func process(input: ProcessInput) throws -> ProcessOutput {
        guard (try? input.inputValues[Self.input]?.values.first?.expectValue()) != nil else {
            return .init(outputValues: [Self.output: .noValue(reason: .inputNotProduced)], inputWireSpecs: [:])
        }
        Thread.sleep(forTimeInterval: Self.seconds)
        return .init(outputValues: [Self.output: .value(try "slow".intern())], inputWireSpecs: [:])
    }
}
