//
//  AutostartTests.swift
//  SemelEndToEndTests
//
//  B-110. A `semel` that finds no server starts one and leaves it running; `semel stop`
//  ends it. Through the real executables, with a home of their own.
//

import Foundation
import XCTest

final class AutostartTests: XCTestCase {

    private var home: URL!

    private var socketPath: String { home.appendingPathComponent("semelserv.sock").path }
    private var environment: [String: String] { ["SEMEL_HOME": home.path, "SEMEL_SOCKET": socketPath] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built")
        // Short, as the harness's roots are: a Unix socket path has 103 bytes, and the
        // process temporary directory plus a UUID is already past that.
        home = URL(fileURLWithPath: "/tmp/semel-autostart/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// A daemon a failed assertion left behind stops the way `stop` stops it.
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    private func semel(_ arguments: String..., step: String) throws -> String {
        try EndToEndRun.run("semel", arguments: arguments, environment: environment, timeout: 60, step: step).output
    }

    func test_semelStartsTheServerItFindsMissingAndLeavesItRunning() throws {
        let first = try semel("ls", step: "first semel, no server")
        XCTAssertTrue(first.contains("Started semelserv (log: \(home.path)/semelserv.log)"), first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "the daemon is left listening")

        let second = try semel("ls", step: "second semel")
        XCTAssertFalse(second.contains("Started semelserv"), "the second client finds the first's daemon: \(second)")
    }

    func test_stopEndsTheServerAndASecondStopFindsNothing() throws {
        _ = try semel("ls", step: "start")

        let stop = try semel("stop", step: "stop")
        XCTAssertTrue(stop.contains("Stopping semelserv at \(socketPath)"), stop)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))

        let again = try semel("stop", step: "stop again")
        XCTAssertTrue(again.contains("No server running at \(socketPath)"), again)
    }
}
