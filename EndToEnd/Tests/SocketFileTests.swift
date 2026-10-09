//
//  SocketFileTests.swift
//  SemelEndToEndTests
//
//  B-73. A test process that crashes or is killed never reaches the harness's SIGTERM,
//  so the `semelserv` it started has to end by another route: its socket file going.
//  That happens when a user deletes the file, and when the sweep in
//  `EndToEndEnvironment.newRoot` removes the stale root the server's home is in.
//

import Foundation
import SemelTestSupport
import XCTest

final class SocketFileTests: XCTestCase {

    private var root: URL!
    private var server: ManagedProcess?

    override func tearDown() {
        if let server, server.isRunning {
            server.kill()
            _ = server.waitForExit(timeout: 5)
        }
        server = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        super.tearDown()
    }

    /// Starts `semelserv` over a home of its own and waits until it answers.
    private func startServer() throws -> (home: URL, socketPath: String, process: ManagedProcess) {
        root = try EndToEndEnvironment.newRoot()
        let home       = root.appendingPathComponent("home", isDirectory: true)
        let socketPath = home.appendingPathComponent("semelserv.sock").path
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let process = ManagedProcess(executable: EndToEndRun.binary("semelserv"), arguments: [],
                                     environment: ["SEMEL_HOME": home.path, "SEMEL_SOCKET": socketPath])
        try process.start()
        server = process
        XCTAssertTrue(SocketWait.wait(forSocketAt: socketPath, timeout: 30), "the server never created \(socketPath)")
        return (home, socketPath, process)
    }

    func test_deletingTheSocketFileStopsTheServerCleanly() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let (_, socketPath, process) = try startServer()

        try FileManager.default.removeItem(atPath: socketPath)

        XCTAssertEqual(process.waitForExit(timeout: 5), 0, process.outputTail())
    }

    /// Removed once the engine is idle. The socket appears while the engine's first pass may
    /// still be running, interning objects and committing to the graph, and a file that
    /// pass creates in a folder the removal has already emptied fails the removal with a
    /// permission error (B-144). A user deleting the home of a busy server sees the same,
    /// and the server stops all the same; what this test pins is the clean stop, so the
    /// removal is the whole home, in one go.
    func test_deletingTheServersHomeStopsTheServerCleanly() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let (home, socketPath, process) = try startServer()
        _ = try EndToEndRun.run("semel", arguments: ["wait"],
                                environment: ["SEMEL_HOME": home.path, "SEMEL_SOCKET": socketPath],
                                timeout: 30, step: "wait for the first settle",
                                serverLog: { process.outputTail() })

        try FileManager.default.removeItem(at: home)

        XCTAssertEqual(process.waitForExit(timeout: 5), 0, process.outputTail())
    }
}
