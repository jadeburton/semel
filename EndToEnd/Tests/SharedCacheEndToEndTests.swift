//
//  SharedCacheEndToEndTests.swift
//  SemelEndToEndTests
//
//  B-153, phase 4: the acceptance run, as far as one Mac allows. `semel-cache serve` on
//  localhost, and three homes that each name it in `semel.engine.config`, as three machines
//  would:
//
//  - Home A builds the C fixture and the C++ one cold, and its queue writes every entry to
//    the shared cache.
//  - Home B, cold, builds the C fixture with every lookup a hit on the shared cache — no
//    miss, no failure, nothing declined — and exports the same bytes as A.
//  - Home C builds the C fixture from the shared cache, then the shared cache is stopped,
//    and C builds the C++ fixture on its own: every lookup a miss that asks nothing, and the
//    same bytes as A again.
//
//  The executables run as a user runs them; the figures are read off `cache` at the prompt.
//

import Foundation
import SemelTestSupport
import XCTest

final class SharedCacheEndToEndTests: XCTestCase {

    private var processes: [ManagedProcess] = []
    private var sessions: [ServerSession] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt && FileManager.default.isExecutableFile(atPath: EndToEndRun.binary("semel-cache").path),
                          "the executables are not built beside the test bundle")
    }

    override func tearDown() {
        for session in sessions {
            session.killIfRunning()
        }
        for process in processes where process.isRunning {
            process.terminate()
            _ = process.waitForExit(timeout: 10)
        }
        sessions = []
        processes = []
        super.tearDown()
    }

    // MARK: - The shared cache

    /// `semel-cache serve` over a home of its own, on a port the system picks, letting every
    /// client write. Its address, read off the banner.
    private func serveCache(home: URL) throws -> (ManagedProcess, String) {
        let process = ManagedProcess(executable: EndToEndRun.binary("semel-cache"),
                                     arguments: ["serve", "--home", home.path, "--listen", "127.0.0.1:0", "--writers", "all"],
                                     environment: [:])
        try process.start()
        processes.append(process)
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            if let line = process.output.components(separatedBy: "\n").first(where: { $0.hasPrefix("Listen:") }) {
                let address = line.dropFirst("Listen:".count).trimmingCharacters(in: .whitespaces)
                return (process, address)
            }
            guard process.isRunning else {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw EndToEndFailure(step: "serve the shared cache", message: "no Listen line within 30 s",
                              commandLine: process.commandLine, outputTail: process.outputTail())
    }

    // MARK: - A home

    /// A fresh home that names the shared cache, and its server started.
    private func home(_ name: String, under root: URL, cache address: String) throws -> ServerSession {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("cache.server    \(address)\ncache.identity  \(name)\n".utf8)
            .write(to: folder.appendingPathComponent("semel.engine.config"))
        let session = ServerSession(home: folder)
        try session.start()
        sessions.append(session)
        return session
    }

    /// `semel` with `commands` against `session`, to the end.
    @discardableResult
    private func semel(_ commands: [String], in session: ServerSession, step: String) throws -> String {
        try EndToEndRun.run("semel", arguments: commands, environment: session.environment, timeout: 300, step: step,
                            serverLog: { session.logTail }).output
    }

    /// The shared cache's figures as `cache` prints them: the numbers on its Lookups and
    /// Writes lines, by the word after each.
    private func figures(in session: ServerSession) throws -> [String: Int] {
        let output = try semel(["cache"], in: session, step: "cache")
        var figures: [String: Int] = [:]
        for line in output.components(separatedBy: "\n") where line.contains("Lookups:") || line.contains("Writes:") {
            let words = line.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ";", with: " ")
                .split(separator: " ").map(String.init)
            for (index, word) in words.enumerated() {
                guard let number = Int(word), index + 1 < words.count else {
                    continue
                }
                figures[words[index + 1]] = number
            }
        }
        guard !figures.isEmpty else {
            throw EndToEndFailure(step: "cache", message: "no shared cache figures in:\n\(output)")
        }
        return figures
    }

    /// Waits until the home's queue has written everything it holds.
    private func waitForTheQueue(of session: ServerSession) throws -> [String: Int] {
        let deadline = Date(timeIntervalSinceNow: 120)
        while true {
            let current = try figures(in: session)
            if current["queued"] == 0, (current["entries"] ?? current["entry"] ?? 0) > 0 {
                return current
            }
            guard Date() < deadline else {
                throw EndToEndFailure(step: "population", message: "the queue did not drain within 120 s: \(current)")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// What each lookup on the shared cache came to, by node type, from a debug server's log:
    /// `using the shared cache: <type>` for a hit, `the shared cache: <outcome> for <type>`
    /// for the rest.
    static func lookups(in log: String) -> [String: [String: Int]] {
        var outcomes: [String: [String: Int]] = [:]
        for line in log.components(separatedBy: "\n") {
            if let range = line.range(of: "using the shared cache: ") {
                let type = line[range.upperBound...].prefix { $0 != "," }
                outcomes["hit", default: [:]][String(type), default: 0] += 1
                continue
            }
            guard let range = line.range(of: "the shared cache: ") else {
                continue
            }
            let rest = line[range.upperBound...]
            guard let forRange = rest.range(of: " for ") else {
                continue
            }
            let outcome = String(rest[..<forRange.lowerBound].prefix { $0 != " " })
            let type = String(rest[forRange.upperBound...].prefix { $0 != "," })
            outcomes[outcome, default: [:]][type, default: 0] += 1
        }
        return outcomes
    }

    private func requireIdentical(_ out: URL, _ other: URL, _ subject: String) throws {
        let differences = try TreeDiff.compare(out, other)
        guard differences.isEmpty else {
            throw EndToEndFailure(step: "byte for byte", message: "\(differences.count) difference(s) \(subject):\n  "
                                + differences.prefix(20).map(\.description).joined(separator: "\n  "))
        }
    }

    // MARK: - The run

    func test_aSecondHomeBuildsFromTheSharedCacheByteForByteAndAThirdFinishesWithoutIt() throws {
        let run = try EndToEndRun(project: Projects.cHello)
        defer { run.cleanUp() }
        try run.materialise()
        try run.configure()
        let root = run.root
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        let (cacheServer, address) = try serveCache(home: root.appendingPathComponent("cache-home", isDirectory: true))

        /// Each build's wall time, printed at the end for the design's figures: a client's
        /// clock, never the engine's.
        var times: [String] = []
        func build(_ folder: String, in session: ServerSession, into out: URL, step: String) throws {
            let started = Date()
            try semel(["base \(tree.path)", "build \(folder) --into \(out.path)", "check"], in: session, step: step)
            times.append("\(step): \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        }
        defer { print("shared cache acceptance timings: \(times.joined(separator: "; "))") }

        // A: cold, both fixtures, and every entry written to the shared cache.
        let homeA = try home("home-a", under: root, cache: address)
        let outA = root.appendingPathComponent("out-a", isDirectory: true)
        try build("c", in: homeA, into: outA.appendingPathComponent("c"), step: "A builds c")
        try build("cpp", in: homeA, into: outA.appendingPathComponent("cpp"), step: "A builds cpp")
        let written = try waitForTheQueue(of: homeA)
        XCTAssertEqual(written["dropped"], 0, "\(written)")
        XCTAssertEqual(written["failed."] ?? 0, 0, "\(written)")
        try homeA.stop()

        // B: cold, every lookup answered by the shared cache, the same bytes.
        let homeB = try home("home-b", under: root, cache: address)
        let outB = root.appendingPathComponent("out-b", isDirectory: true)
        try build("c", in: homeB, into: outB.appendingPathComponent("c"), step: "B builds c")
        let read = try figures(in: homeB)
        let lookups = Self.lookups(in: homeB.log)
        print("home B's lookups on the shared cache, by outcome and node type: \(lookups)")
        XCTAssertGreaterThan(read["hits"] ?? 0, 0, "\(read)")
        XCTAssertEqual(read["misses"], 0, "a cold home finds every build on the shared cache: \(read)")
        XCTAssertEqual(read["failed"], 0, "\(read)")
        for tool in ["ClangPreprocessor", "ClangCompiler", "ClangLinker"] {
            XCTAssertGreaterThan(lookups["hit"]?[tool] ?? 0, 0, "\(tool) came from the shared cache: \(lookups)")
            for outcome in lookups.keys where outcome != "hit" {
                XCTAssertNil(lookups[outcome]?[tool], "every \(tool) came from the shared cache: \(lookups)")
            }
        }
        try requireIdentical(outA.appendingPathComponent("c"), outB.appendingPathComponent("c"), "between A's build and B's from the cache")
        try homeB.stop()

        // C: the C fixture from the shared cache, then the cache stopped, then the C++ fixture
        // built here with every lookup a miss that asks nothing.
        let homeC = try home("home-c", under: root, cache: address)
        let outC = root.appendingPathComponent("out-c", isDirectory: true)
        try build("c", in: homeC, into: outC.appendingPathComponent("c"), step: "C builds c")
        let beforeTheStop = try figures(in: homeC)
        XCTAssertGreaterThan(beforeTheStop["hits"] ?? 0, 0, "\(beforeTheStop)")
        cacheServer.terminate()
        XCTAssertEqual(cacheServer.waitForExit(timeout: 30), 0, cacheServer.outputTail())
        try build("cpp", in: homeC, into: outC.appendingPathComponent("cpp"), step: "C builds cpp with the cache stopped")
        let afterTheStop = try figures(in: homeC)
        print("home A wrote \(written); home C before the stop \(beforeTheStop), after it \(afterTheStop)")
        XCTAssertEqual(afterTheStop["hits"], beforeTheStop["hits"], "nothing more came from a stopped cache: \(afterTheStop)")
        XCTAssertGreaterThan((afterTheStop["failed"] ?? 0) + (afterTheStop["while"] ?? 0), 0,
                             "the lookups after the stop were misses: \(afterTheStop)")
        try requireIdentical(outA.appendingPathComponent("c"), outC.appendingPathComponent("c"), "between A and C's c")
        try requireIdentical(outA.appendingPathComponent("cpp"), outC.appendingPathComponent("cpp"),
                             "between A's cpp and C's, built with the cache stopped")
        try homeC.stop()
    }
}
