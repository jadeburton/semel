//
//  MonitorEndToEndTests.swift
//  SemelEndToEndTests
//
//  B-150. `semel-monitor --print` as a script runs it, against a real `semelserv` over
//  the C fixture: started before any engine, it says so and waits; a build's settle is a
//  running card while its compiles run and then its card's lines; `show` writes the live
//  window with the settle's counts and products, and a click on the card opens the
//  products window over `output:`; the engine stopped and started again, it reconnects on
//  its own, reports the next settle, and *Products…* and the live window show what that
//  settle changed.
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
                                     environment: server.environment, takesInput: true)
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

        // While the compiles ran, the settle was a running card, which became the card above.
        let beforeCard = try XCTUnwrap(monitor.output.components(separatedBy: "card: 3 products appeared\n").first)
        XCTAssertNotNil(beforeCard.range(of: #"(^|\n)running: Building · \d+ running · \d+ ahead\n"#,
                                         options: .regularExpression), monitor.output)

        // *Show window*: the live window, idle now, with the settle's counts and its products.
        monitor.write(line: "show")
        let live = "live: semel · idle\n"
        try waitUntil("the live window", monitor: monitor, server: server) {
            monitor.output.contains(live)
        }
        try assertLiveWindow(after: live, in: monitor.output, lastSettle: "3 products appeared",
                             rows: ["c: config.txt · appeared", "c: hello · appeared", "c: hello.dylib · appeared"])

        // A click opens the window for the card's settle, on its folder, and the card goes.
        monitor.write(line: "click")
        let clicked = "dismissed: 3 products appeared\nwindow: 3 products appeared\n  output: · [c] · Errors (0)\n"
        try waitUntil("the window the click opens", monitor: monitor, server: server) {
            monitor.output.contains(clicked)
        }
        try assertRows(after: clicked, in: monitor.output, marks: ["config.txt": "appeared", "hello": "appeared",
                                                                   "hello.dylib": "appeared"])

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

        // *Products…* marks what the newest settle changed.
        monitor.write(line: "products")
        let opened = "window: products\n  output: · [c] · Errors (0)\n"
        try waitUntil("the window Products… opens", monitor: monitor, server: server) {
            monitor.output.contains(opened)
        }
        try assertRows(after: opened, in: monitor.output, marks: ["config.txt": nil, "hello": "changed",
                                                                  "hello.dylib": "changed"])

        // And the live window follows the engine across the restart to the newest settle.
        monitor.write(line: "show")
        try waitUntil("the live window after the reconnection", monitor: monitor, server: server) {
            Self.count(of: live, in: monitor.output) == 2
        }
        try assertLiveWindow(after: live, in: monitor.output, lastSettle: "2 products changed",
                             rows: ["c: hello · changed", "c: hello.dylib · changed"])
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

    /// The window's rows after its first lines: each product of the C fixture by name, with
    /// its mark when it has one, and a size — the numbers are the compiler's, the form is not.
    private func assertRows(after opening: String, in output: String, marks: [String: String?]) throws {
        let window = try XCTUnwrap(output.components(separatedBy: opening).last, output)
        let rows = window.split(separator: "\n").prefix(marks.count).map(String.init)
        XCTAssertEqual(rows.count, marks.count, output)
        for (row, name) in zip(rows, marks.keys.sorted()) {
            let mark = (marks[name] ?? nil).map { " · \($0)" } ?? ""
            let pattern = "^  " + NSRegularExpression.escapedPattern(for: name + mark) + #" · \d+(\.\d)? (bytes|KB|MB)$"#
            XCTAssertNotNil(row.range(of: pattern, options: .regularExpression), "\(row)\n\(output)")
        }
    }

    /// The live window's lines after its title: the last settle's counts, the bar's two
    /// numbers equal once it has ended, nothing running, and its products — the numbers
    /// are the engine's, the form is not.
    private func assertLiveWindow(after title: String, in output: String, lastSettle: String, rows: [String]) throws {
        let window = try XCTUnwrap(output.components(separatedBy: title).last, output)
        let lines = window.split(separator: "\n").prefix(4 + rows.count).map(String.init)
        XCTAssertEqual(lines.count, 4 + rows.count, output)
        XCTAssertNotNil(lines[0].range(of: #"^  scheduled \d+ · computed \d+ · from cache \d+ · errors 0$"#,
                                       options: .regularExpression), output)
        XCTAssertNotNil(lines[1].range(of: #"^  started (\d+) of \1$"#, options: .regularExpression), output)
        XCTAssertEqual(Array(lines.dropFirst(2)), ["  nothing running", "  last settle: \(lastSettle)"] + rows.map { "  \($0)" },
                       output)
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
