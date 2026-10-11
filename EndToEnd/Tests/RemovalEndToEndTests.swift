//
//  RemovalEndToEndTests.swift
//  SemelEndToEndTests
//
//  B-149. `rm` through the real executables: the C fixture built, then removed. The
//  removal's settle lets go of the project, writes no cache entry and leaves no error
//  behind; a source removed from a project that stays is named as removed and no tool says
//  anything about it.
//

import Foundation
import SemelTestSupport
import XCTest

final class RemovalEndToEndTests: XCTestCase {

    private var home: URL?

    private func requireHome() throws -> URL {
        try XCTUnwrap(home)
    }

    private var socketPath: String {
        (home?.appendingPathComponent("semelserv.sock").path) ?? ""
    }

    private var environment: [String: String] {
        ["SEMEL_HOME": home?.path ?? "", "SEMEL_SOCKET": socketPath]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built")
        // Short, as the harness's roots are: a Unix socket path has 103 bytes.
        let home = URL(fileURLWithPath: "/tmp/semel-rm/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        self.home = home
    }

    /// The server this test started is stopped, and its home goes with it.
    override func tearDown() {
        if home != nil {
            _ = try? EndToEndRun.run("semel", arguments: ["stop"], environment: environment, timeout: 30, step: "stop")
        }
        if let home {
            try? FileManager.default.removeItem(at: home)
        }
        super.tearDown()
    }

    /// One `semel` session over the server, its output whatever its status.
    private func semel(_ arguments: String..., step: String) throws -> String {
        let process = ManagedProcess(executable: EndToEndRun.binary("semel"), arguments: arguments, environment: environment)
        try process.start()
        guard process.waitForExit(timeout: 120) != nil else {
            process.kill()
            _ = process.waitForExit(timeout: 5)
            throw EndToEndFailure(step: step, message: "timed out", commandLine: process.commandLine, outputTail: process.outputTail())
        }
        return process.output
    }

    /// The C fixture beside its machine file, built clean. Returns the tree it is under.
    private func buildFixture() throws -> URL {
        let tree = try requireHome().appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: EndToEndEnvironment.fixtures.appendingPathComponent("c", isDirectory: true),
                                         to: tree.appendingPathComponent("c", isDirectory: true))
        _ = try EndToEndRun.run("semel-clang", arguments: [tree.path], environment: environment, timeout: 60, step: "semel-clang")
        let output = try semel("base \(tree.path)", "build c", step: "build")
        XCTAssertTrue(output.contains("No errors."), output)
        return tree
    }

    /// The settle summary's line: scheduled, computed, from cache.
    private func summary(in output: String) throws -> (scheduled: Int, computed: Int, fromCache: Int) {
        let line = try XCTUnwrap(output.components(separatedBy: "\n").last { $0.contains(" nodes scheduled, ") }, output)
        let numbers = line.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        XCTAssertGreaterThanOrEqual(numbers.count, 3, line)
        return (numbers[0], numbers[1], numbers[2])
    }

    /// How many entries `cache` says the cache holds.
    private func cacheEntryCount() throws -> Int {
        let output = try semel("cache", step: "cache")
        let line   = try XCTUnwrap(output.components(separatedBy: "\n").first { $0.contains(" against a limit of ") }, output)
        return try XCTUnwrap(Int(line.prefix { $0.isNumber }), line)
    }

    /// The C toolchain's entries `cache` lists, by type and key: one per entry a tool's run
    /// wrote. The notes after the key — held, used — move with every settle and are left out.
    private func toolEntries() throws -> [String] {
        try semel("cache", step: "cache").components(separatedBy: "\n").filter { $0.contains(" Clang") }
            .map { line in
                let columns = line.split(separator: " ")
                return columns.count >= 6 ? "\(columns[4]) \(columns[5])" : line
            }
            .sorted()
    }

    /// Which nodes compute in the removal's settle is not pinned, only that no tool does.
    /// The removal wakes the finder and, in the same round, the nodes reading the removed
    /// sources: a tool among them is stopped by the state its input stands in, but a node
    /// that tolerates an absent value — the `ConfigMerger` over the project's `semel.config`,
    /// a `ClangIncludeFinder` over a source — runs beside the finder, and whether its result
    /// is written before the finder's write lets go of it, or dropped because the collector
    /// took it first, is the order two threads finish in (B-156). That no tool is started is
    /// held where a run can be counted, in `RemovalSettleTests`; here the run is held to what
    /// a client sees: nothing answered from the cache, no entry written, no error, and
    /// nothing of the project left in either file system.
    func test_removingTheFixtureLetsGoOfItAndWritesNoEntry() throws {
        let tree    = try buildFixture()
        let entries = try cacheEntryCount()

        let inputBefore  = try semel("ls", step: "ls")
        let outputBefore = try semel("ls -o", step: "ls -o")
        XCTAssertTrue(listsTheProject(inputBefore), "the project is in input: to remove\n\(inputBefore)")
        XCTAssertTrue(listsTheProject(outputBefore), "and its products in output:\n\(outputBefore)")

        let output = try semel("base \(tree.path)", "rm c", "wait", "errors", step: "rm")

        XCTAssertEqual(try summary(in: output).fromCache, 0, output)
        XCTAssertTrue(output.contains("No errors."), output)
        XCTAssertEqual(try cacheEntryCount(), entries, "a removal writes no entry")

        let inputListing = try semel("ls", step: "ls")
        XCTAssertFalse(listsTheProject(inputListing), "nothing of the project is left in input:\n\(inputListing)")
        let outputListing = try semel("ls -o", step: "ls -o")
        XCTAssertFalse(listsTheProject(outputListing), "the finder let go of its products:\n\(outputListing)")
    }

    /// Whether `ls` named the fixture's folder, `c/`, in whatever state.
    private func listsTheProject(_ listing: String) -> Bool {
        listing.components(separatedBy: "\n").contains { $0.split(separator: " ").contains("c/") }
    }

    /// The machine file every tool's settings are read from, named by path in the formula:
    /// removed, it is what the report names, and no tool runs over it or stores anything. The
    /// project builder, which reads the listing the removal changed, may run and store its
    /// own answer; nothing below it does.
    func test_aRemovedSourceIsNamedAsRemovedAndNoToolRunsOverIt() throws {
        let tree  = try buildFixture()
        let tools = try toolEntries()

        let output = try semel("base \(tree.path)", "rm semel.machine.config", "wait", "errors", step: "rm")

        XCTAssertTrue(output.contains("semel.machine.config has been removed"), output)
        XCTAssertFalse(output.contains("error:"), "no tool ran over the removed file:\n\(output)")
        XCTAssertLessThanOrEqual(try summary(in: output).computed, 2, "the finder and the builder at most:\n\(output)")
        XCTAssertEqual(try toolEntries(), tools, "no tool's run is stored")
    }
}
