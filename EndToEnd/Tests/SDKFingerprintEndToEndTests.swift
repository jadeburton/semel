//
//  SDKFingerprintEndToEndTests.swift
//  SemelEndToEndTests
//
//  B-47. An SDK that changes under a built graph — an Xcode update that keeps the version
//  and build, a header edited in place — reaches the graph as a changed `sdkFingerprint`
//  line in the pushed machine file, which reschedules every node reading the namespace it
//  is under. The C fixture, built by the real executables: the clang compiler's line is
//  changed by hand, as a rewrite after an update would change it, and every compile's
//  configuration moves, where an edit the compilers do not read moves none of them.
//

import Foundation
import SemelTestSupport
import XCTest

final class SDKFingerprintEndToEndTests: XCTestCase {

    private var root: URL?
    private var server: ServerSession?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built")
        root = try EndToEndEnvironment.newRoot()
    }

    override func tearDown() {
        server?.killIfRunning()
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    /// The C fixture's compiles, one per source and shared by the executable and the
    /// library, each named by the preprocessed source on its `input` wire.
    private static let compiledSources = ["input:/c/src/hello.c.p", "input:/c/src/hello2.c.p", "input:/c/src/main.c.p"]

    /// Asserted on what each compile reads, not on how many nodes a settle computed. The
    /// comment edit wakes the compiles too: the merged settings run again, and every node
    /// below them is pending until its input is written again. A compile woken with the
    /// key it had is answered from the cache only if its earlier run took long enough to
    /// store an entry — the 15 ms floor in `saveCacheForAllInputsAndOutputs` — so either
    /// settle's `computed` count moves by up to three with the machine's load. A changed
    /// configuration is a changed key, which no entry answers: a compile whose
    /// configuration moved is a compile that ran.
    func test_aChangedSDKFingerprintLineReschedulesTheCompiles() throws {
        let root = try XCTUnwrap(self.root)
        let tree = root.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: EndToEndEnvironment.fixtures.appendingPathComponent("c", isDirectory: true),
                                         to: tree.appendingPathComponent("c", isDirectory: true))
        try EndToEndRun.run("semel-clang", arguments: [tree.path], timeout: 60, step: "semel-clang")
        let machineFile = tree.appendingPathComponent("semel.machine.config")
        let written = try String(contentsOf: machineFile, encoding: .utf8)
        let line = try XCTUnwrap(written.components(separatedBy: "\n").first { $0.hasPrefix("clang.compiler.sdkFingerprint=") },
                                 "semel-clang writes the SDK's fingerprint under the compiler's namespace:\n\(written)")

        let server = ServerSession(home: root.appendingPathComponent("home", isDirectory: true))
        self.server = server
        try server.start()
        let first = try build(tree: tree, server: server, step: "first build")
        XCTAssertTrue(first.contains("   appeared: output:/c/hello\n"), first)
        let built = try compileConfigurations(server: server, step: "graph after the first build")
        XCTAssertEqual(built.keys.sorted(), Self.compiledSources, "one compile per source")

        // An edit no compiler reads: the file is pushed again, as the product that shows
        // it says, and every compile reads what it read before.
        try (written + "// a comment, read by nobody\n").write(to: machineFile, atomically: true, encoding: .utf8)
        let commented = try build(tree: tree, server: server, step: "build after a comment")
        XCTAssertTrue(commented.contains("   changed: output:/c/config.txt\n"), commented)
        XCTAssertEqual(try compileConfigurations(server: server, step: "graph after a comment"), built,
                       "a comment in the machine file changes no compile's configuration")

        // The compiler's fingerprint line, as a rewrite after an SDK update writes it.
        try written.replacingOccurrences(of: line, with: "clang.compiler.sdkFingerprint=an-sdk-updated-in-place")
            .write(to: machineFile, atomically: true, encoding: .utf8)
        _ = try build(tree: tree, server: server, step: "build after the SDK changed")
        let updated = try compileConfigurations(server: server, step: "graph after the SDK changed")
        XCTAssertEqual(updated.keys.sorted(), Self.compiledSources, "one compile per source")
        for source in Self.compiledSources {
            XCTAssertNotEqual(updated[source], built[source],
                              "the compile of \(source) reads the fingerprint line, so it runs again")
        }
        try server.stop()
    }

    /// `build c` over the tree, with the machine file pushed first: `build` pushes the
    /// folder it names, and a file outside it only when the graph has none, so what pushes
    /// a changed machine file is a `push` — the watcher's, or `prepare`'s user's.
    private func build(tree: URL, server: ServerSession, step: String) throws -> String {
        try EndToEndRun.run("semel", arguments: ["base \(tree.path)", "push semel.machine.config", "build c"],
                            environment: server.environment, timeout: 120, step: step, serverLog: { server.logTail }).output
    }

    /// The value on each compile's `configuration` wire, keyed by the source on its `input`
    /// wire. Read from `debug`'s dump of the graph, the one place a client sees a node's
    /// inputs: the hash at the head of the bracket in
    /// `· configuration  ◀──(wire0)── #25 ? [40043480]:output   [ 5e6061755093…  "cStandard=…" ]`.
    private func compileConfigurations(server: ServerSession, step: String) throws -> [String: String] {
        let dump = try EndToEndRun.run("semel", arguments: ["debug"], environment: server.environment,
                                       timeout: 60, step: step, serverLog: { server.logTail }).output
        var configurations: [String: String] = [:]
        for block in dump.components(separatedBy: "\n⬢ ") where block.hasPrefix("ClangCompiler #") {
            let lines             = block.components(separatedBy: "\n")
            let inputLine         = try XCTUnwrap(lines.first { $0.contains("· input  ◀──(") }, block)
            let configurationLine = try XCTUnwrap(lines.first { $0.contains("· configuration  ◀──(") }, block)
            let source = try XCTUnwrap(Self.text(in: inputLine, after: "◀──(", before: ")──"), inputLine)
            let value  = try XCTUnwrap(Self.text(in: configurationLine, after: "]:output   [ ", before: "  "), configurationLine)
            XCTAssertNil(configurations[source], "two compiles of \(source):\n\(dump)")
            configurations[source] = value
        }
        return configurations
    }

    /// What lies in `line` between the first `opening` and the first `closing` after it.
    private static func text(in line: String, after opening: String, before closing: String) -> String? {
        guard let start = line.range(of: opening)?.upperBound,
              let end = line.range(of: closing, range: start..<line.endIndex)?.lowerBound else {
            return nil
        }
        return String(line[start..<end])
    }
}
