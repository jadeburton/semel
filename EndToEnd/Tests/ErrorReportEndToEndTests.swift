//
//  ErrorReportEndToEndTests.swift
//  SemelEndToEndTests
//
//  The error report as a person reads it (the 2026-10-09 design): the C fixture built by
//  the real executables with a deliberate error in one source, and the report under the
//  build compared line for line — the tool's own diagnostic with the path as it is on disk,
//  under the heading of the products that need it, what it belongs to, and the summary.
//

import Foundation
import SemelTestSupport
import XCTest

final class ErrorReportEndToEndTests: XCTestCase {

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
        let home = URL(fileURLWithPath: "/tmp/semel-report/\(UUID().uuidString.prefix(8))", isDirectory: true)
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

    /// A failing run: the output comes back, and the non-zero status is asserted.
    private func semelExpectingFailure(_ arguments: String..., step: String) throws -> String {
        let process = ManagedProcess(executable: EndToEndRun.binary("semel"), arguments: arguments, environment: environment)
        try process.start()
        guard let status = process.waitForExit(timeout: 120) else {
            process.kill()
            _ = process.waitForExit(timeout: 5)
            throw EndToEndFailure(step: step, message: "timed out", commandLine: process.commandLine, outputTail: process.outputTail())
        }
        XCTAssertNotEqual(status, 0, "\(step): expected a failing build, got:\n\(process.output)")
        return process.output
    }

    /// `#error` stops the preprocessor of one source, with a diagnostic whose wording is the
    /// directive's own; the two products that source is compiled into have no value, the
    /// third — the machine file, copied — has one, and nothing is exported.
    func test_aFailedBuildOfTheCFixtureReadsLineForLine() throws {
        let tree = try requireHome().appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let fixture = tree.appendingPathComponent("c", isDirectory: true)
        try FileManager.default.copyItem(at: EndToEndEnvironment.fixtures.appendingPathComponent("c", isDirectory: true), to: fixture)
        let source = fixture.appendingPathComponent("src/hello.c")
        let text = try String(contentsOf: source, encoding: .utf8)
        try text.replacingOccurrences(of: "#include \"hello.h\"\n", with: "#include \"hello.h\"\n#error \"deliberate\"\n")
            .write(to: source, atomically: true, encoding: .utf8)
        _ = try EndToEndRun.run("semel-clang", arguments: [tree.path], environment: environment, timeout: 60, step: "semel-clang")

        let output = try semelExpectingFailure("base \(tree.path)", "build c", step: "build with an error")

        // From under the settle's own summary — the artifact diff, then the report — to the
        // report's summary line.
        let lines = output.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("❌ ") }, output) + 1
        let end   = try XCTUnwrap(lines[start...].firstIndex { $0.hasPrefix("1 error · ") }, output)
        XCTAssertEqual(Array(lines[start...end]), [
            "   appeared: output:/c/config.txt",
            "hello, hello.dylib:",
            "c/src/hello.c:10:2: error: \"deliberate\"",
            "     10 | #error \"deliberate\"",
            "        |  ^",
            "  1 error generated.",
            "  source: c/src/hello.c",
            "",
            "1 error · 2 products without a value · nothing exported",
        ], output)
    }
}
