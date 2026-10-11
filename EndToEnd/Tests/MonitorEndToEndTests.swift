//
//  MonitorEndToEndTests.swift
//  SemelEndToEndTests
//
//  B-150. `semel-monitor --print` as a script runs it, against a real `semelserv` over
//  the C fixture: started before any engine, it says so and waits; a build's settle is
//  its card's lines; the engine stopped and started again, it reconnects on its own and
//  reports the next settle.
//

import Foundation
import SemelTestSupport
import XCTest

final class MonitorEndToEndTests: XCTestCase {

    private var root: URL?
    private var server: ServerSession?
    private var monitor: ManagedProcess?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built")
        root = try EndToEndEnvironment.newRoot()
    }

    override func tearDown() {
        monitor?.terminate()
        _ = monitor?.waitForExit(timeout: 5)
        monitor?.kill()
        try? server?.stop()
        server?.killIfRunning()
        if let root, !EndToEndEnvironment.keepsRoots {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    func test_aSettleIsACardAndTheMonitorOutlivesTheEngine() throws {
        let root = try XCTUnwrap(self.root)
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: EndToEndEnvironment.fixtures.appendingPathComponent("c", isDirectory: true),
                                         to: tree.appendingPathComponent("c", isDirectory: true))
        try EndToEndRun.run("semel-clang", arguments: [tree.path], timeout: 60, step: "semel-clang")

        let server = ServerSession(home: root.appendingPathComponent("home", isDirectory: true))
        self.server = server

        // Before the engine: the monitor starts none, and says there is none.
        let monitor = ManagedProcess(executable: EndToEndRun.binary("semel-monitor"), arguments: ["--print"],
                                     environment: server.environment)
        self.monitor = monitor
        try monitor.start()
        try waitUntil("the monitor sees no engine", monitor: monitor, server: server) {
            monitor.output.contains("status: no engine\n")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.socketPath), "the monitor started no server")

        try server.start()
        try waitUntil("the monitor connects", monitor: monitor, server: server) {
            Self.count(of: "status: connected\n", in: monitor.output) == 1
        }

        try EndToEndRun.run("semel", arguments: ["base \(tree.path)", "build c"], environment: server.environment,
                            timeout: 120, step: "build", serverLog: { server.logTail })
        try waitUntil("the build's card", monitor: monitor, server: server) {
            monitor.output.contains("card: 3 products appeared\n  config.txt, hello, hello.dylib\n")
        }
        try assertCountsLine(after: "card: 3 products appeared\n", in: monitor.output)

        // The engine goes and comes back; the monitor follows it without being restarted.
        try server.stop()
        try waitUntil("the monitor loses the engine", monitor: monitor, server: server) {
            Self.count(of: "status: no engine\n", in: monitor.output) == 2
        }
        try server.start()
        try waitUntil("the monitor reconnects", monitor: monitor, server: server) {
            Self.count(of: "status: connected\n", in: monitor.output) == 2
        }

        let source = tree.appendingPathComponent("c/src/hello.c")
        let edited = try String(contentsOf: source, encoding: .utf8)
            .replacingOccurrences(of: "Hello, World 1!", with: "Hello from the monitor's test!")
        try edited.write(to: source, atomically: true, encoding: .utf8)
        try EndToEndRun.run("semel", arguments: ["base \(tree.path)", "push c/src/hello.c", "wait"],
                            environment: server.environment, timeout: 120, step: "push", serverLog: { server.logTail })
        try waitUntil("the card of the settle after the reconnection", monitor: monitor, server: server) {
            monitor.output.contains("card: 2 products changed\n  hello, hello.dylib\n")
        }
        try assertCountsLine(after: "card: 2 products changed\n", in: monitor.output)
        print("semel-monitor --print:\n\(monitor.output)")
    }

    // MARK: - Helpers

    /// The line after a card's names is its counts, `24 computed · 0 from cache`: the
    /// numbers are the engine's and vary with the cache, the form does not.
    private func assertCountsLine(after headline: String, in output: String) throws {
        let card = try XCTUnwrap(output.components(separatedBy: headline).last, output)
        let lines = card.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertGreaterThan(lines.count, 1, output)
        let counts = String(lines[1])
        XCTAssertNotNil(counts.range(of: #"^  \d+ computed · \d+ from cache$"#, options: .regularExpression), output)
    }

    private func waitUntil(_ step: String, timeout: TimeInterval = 60, monitor: ManagedProcess, server: ServerSession,
                           _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: TimeInterval = 0.05
        while try !condition() {
            guard Date() < deadline, monitor.isRunning else {
                throw EndToEndFailure(step: step,
                                      message: monitor.isRunning ? "not within \(Int(timeout)) s" : "semel-monitor exited",
                                      commandLine: monitor.commandLine, outputTail: monitor.outputTail(),
                                      serverLogTail: server.logTail)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private static func count(of text: String, in output: String) -> Int {
        output.components(separatedBy: text).count - 1
    }
}
