//
//  SDKFingerprintEndToEndTests.swift
//  SemelEndToEndTests
//
//  B-47. An SDK that changes under a built graph — an Xcode update that keeps the version
//  and build, a header edited in place — reaches the graph as a changed `sdkFingerprint`
//  line in the pushed machine file, which reschedules every node reading the namespace it
//  is under. The C fixture, built by the real executables: the clang compiler's line is
//  changed by hand, as a rewrite after an update would change it, and the compiles run
//  again where an edit the compilers do not read wakes none of them.
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

    /// The C fixture compiles three sources, one compile each, shared by the executable
    /// and the library.
    private static let compiledSources = 3

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

        // An edit no compiler reads: the file is pushed again, and the compiles stay as
        // they were.
        try (written + "// a comment, read by nobody\n").write(to: machineFile, atomically: true, encoding: .utf8)
        let unread = try computed(in: try build(tree: tree, server: server, step: "build after a comment"))

        // The compiler's fingerprint line, as a rewrite after an SDK update writes it.
        try written.replacingOccurrences(of: line, with: "clang.compiler.sdkFingerprint=an-sdk-updated-in-place")
            .write(to: machineFile, atomically: true, encoding: .utf8)
        let changed = try computed(in: try build(tree: tree, server: server, step: "build after the SDK changed"))

        XCTAssertGreaterThanOrEqual(changed, unread + Self.compiledSources,
                                    "each compile reads the fingerprint line, so each runs again")
        try server.stop()
    }

    /// `build c` over the tree, with the machine file pushed first: `build` pushes the
    /// folder it names, and a file outside it only when the graph has none, so what pushes
    /// a changed machine file is a `push` — the watcher's, or `prepare`'s user's.
    private func build(tree: URL, server: ServerSession, step: String) throws -> String {
        try EndToEndRun.run("semel", arguments: ["base \(tree.path)", "push semel.machine.config", "build c"],
                            environment: server.environment, timeout: 120, step: step, serverLog: { server.logTail }).output
    }

    /// The `computed` count of the settle summary — `✅ 9 nodes scheduled, 6 computed, …` —
    /// or zero when nothing was scheduled and there is no summary.
    private func computed(in output: String) throws -> Int {
        guard let summary = output.components(separatedBy: "\n").last(where: { $0.contains(" scheduled, ") && $0.contains(" computed, ") }) else {
            return 0
        }
        let words = summary.components(separatedBy: " ")
        let index = try XCTUnwrap(words.firstIndex(of: "computed,"), summary)
        return try XCTUnwrap(Int(words[index - 1]), summary)
    }
}
