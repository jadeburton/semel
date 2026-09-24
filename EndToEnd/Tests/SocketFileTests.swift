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

    func test_deletingTheServersHomeStopsTheServerCleanly() throws {
        try XCTSkipUnless(EndToEndRun.binariesAreBuilt, "the executables are not built beside the test bundle")
        let (home, _, process) = try startServer()

        try FileManager.default.removeItem(at: home)

        XCTAssertEqual(process.waitForExit(timeout: 5), 0, process.outputTail())
    }
}
