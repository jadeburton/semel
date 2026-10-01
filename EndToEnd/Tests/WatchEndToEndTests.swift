//
//  WatchEndToEndTests.swift
//  SemelEndToEndTests
//
//  B-126. `semel-watch` as a user runs it: a process over a copy of the C fixture, a
//  real FSEvents stream, `semelserv` beside it — and a file edited on disk changing the
//  exported product, with nobody typing a push. The one place the FSEvents adapter runs.
//

import Foundation
import SemelTestSupport
import XCTest

final class WatchEndToEndTests: XCTestCase {

    private var root: URL?
    private var server: ServerSession?
    private var watcher: ManagedProcess?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built")
        root = try EndToEndEnvironment.newRoot()
    }

    override func tearDown() {
        watcher?.kill()
        _ = watcher?.waitForExit(timeout: 5)
        server?.killIfRunning()
        if let root {
            if EndToEndEnvironment.keepsRoots {
                print("SEMEL_E2E_KEEP=1: kept \(root.path)")
            } else {
                try? FileManager.default.removeItem(at: root)
            }
        }
        super.tearDown()
    }

    /// The first build is the watcher's initial push; the second is a save. Between the
    /// save and the settle summary is two seconds of quiet, the stream's latency and the
    /// build, which the test prints so a regression in any of them is seen.
    func test_aFileSavedOnDiskChangesTheExportedProduct() throws {
        let root = try XCTUnwrap(self.root)
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        let out  = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: EndToEndEnvironment.fixtures.appendingPathComponent("c", isDirectory: true),
                                         to: tree.appendingPathComponent("c", isDirectory: true))
        try EndToEndRun.run("semel-clang", arguments: [tree.path], timeout: 60, step: "semel-clang")

        let server = ServerSession(home: root.appendingPathComponent("home", isDirectory: true))
        self.server = server
        try server.start()

        let watcher = ManagedProcess(executable: EndToEndRun.binary("semel-watch"),
                                     arguments: [tree.path, "c", "--into", out.path],
                                     environment: server.environment)
        self.watcher = watcher
        try watcher.start()

        let product = out.appendingPathComponent("hello")
        try waitUntil("the initial push is built and exported", timeout: 120, watcher: watcher, server: server) {
            Self.count(of: "Exported 3 files", in: watcher.output) == 1 && FileManager.default.fileExists(atPath: product.path)
        }
        XCTAssertTrue(watcher.output.contains("c/hello.fmla needs ../semel.machine.config"), watcher.output)
        let built = try Data(contentsOf: product)
        let summariesBefore = Self.settleSummaries(in: watcher.output)

        let source = tree.appendingPathComponent("c/src/hello.c")
        let edited = try String(contentsOf: source, encoding: .utf8)
            .replacingOccurrences(of: "Hello, World 1!", with: "Hello from a save!")
        let saved = Date()
        try edited.write(to: source, atomically: true, encoding: .utf8)

        try waitUntil("a settle after the save", timeout: 60, watcher: watcher, server: server) {
            Self.settleSummaries(in: watcher.output) > summariesBefore
        }
        let saveToSummary = Date().timeIntervalSince(saved)
        print("semel-watch: \(String(format: "%.2f", saveToSummary)) s from the save to the settle summary")

        try waitUntil("the save is exported", timeout: 60, watcher: watcher, server: server) {
            Self.count(of: "Exported 3 files", in: watcher.output) == 2
        }
        XCTAssertNotEqual(try Data(contentsOf: product), built, "the export holds the saved source's product")
        XCTAssertTrue(watcher.output.contains("Push file: c/src/hello.c\n"), watcher.output)
        XCTAssertTrue(watcher.output.contains("   changed: output:/c/hello\n"), watcher.output)

        // SIGTERM ends the stream and the loop; the engine is left running for the next
        // client, and stops cleanly after.
        watcher.terminate()
        let status = watcher.waitForExit(timeout: 10)
        XCTAssertEqual(status, 0, watcher.outputTail())
        try server.stop()
    }

    // MARK: - Helpers

    /// Polls `condition` until it holds or `timeout` passes, failing with the watcher's
    /// output and the server's log as the evidence.
    private func waitUntil(_ step: String, timeout: TimeInterval, watcher: ManagedProcess, server: ServerSession,
                           _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: TimeInterval = 0.02
        while try !condition() {
            guard Date() < deadline, watcher.isRunning else {
                throw EndToEndFailure(step: step,
                                      message: watcher.isRunning ? "not within \(Int(timeout)) s" : "semel-watch exited",
                                      commandLine: watcher.commandLine, outputTail: watcher.outputTail(),
                                      serverLogTail: server.logTail)
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// The settle summaries printed so far: `✅ 9 nodes scheduled, …` or the same under ❌.
    private static func settleSummaries(in output: String) -> Int {
        output.split(separator: "\n").filter { $0.contains(" scheduled, ") && $0.contains(" computed, ") }.count
    }

    private static func count(of text: String, in output: String) -> Int {
        output.components(separatedBy: text).count - 1
    }
}
