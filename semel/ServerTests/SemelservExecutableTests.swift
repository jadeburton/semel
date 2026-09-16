//
//  SemelservExecutableTests.swift
//  SemelServerTests
//
//  The binary, as a subprocess, with SEMEL_HOME and SEMEL_SOCKET pointing into a
//  temporary directory so it never opens the user's graph or socket. What is pinned:
//  it comes up and answers hello, a second instance is refused, and SIGTERM stops it
//  cleanly with the socket file gone.
//

import Foundation
@testable import SemelCLI
import SemelProtocol
import XCTest

final class SemelservExecutableTests: XCTestCase {

    private var home: URL!
    private var socketPath: String!
    private var processes: [Process] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: the socket lives under the home, and a Unix-domain socket path
        // is limited to 103 bytes on macOS.
        home = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        socketPath = home.appendingPathComponent("semelserv.sock").path
    }

    override func tearDown() {
        for process in processes where process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        processes = []
        try? FileManager.default.removeItem(at: home)
        home = nil
        super.tearDown()
    }

    /// The products directory holds the test bundle and the executables built beside it.
    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("semelserv")
    }

    private func launch() throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = binary
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["SEMEL_HOME": home.path, "SEMEL_SOCKET": socketPath]) { _, override in override }
        let output = Pipe()
        process.standardOutput = output
        process.standardError  = output
        try process.run()
        processes.append(process)
        return (process, output)
    }

    private func waitForSocket() -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    func test_startsAnswersHelloRefusesASecondInstanceAndStopsOnSigterm() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path),
                          "semelserv is not built beside the test bundle at \(binary.path)")

        let (server, _) = try launch()
        XCTAssertTrue(waitForSocket(), "the server never created \(socketPath!)")

        let client = try SocketConnection.connect(to: socketPath)
        let (reply, _) = try client.send(.hello(Hello(role: .daemon)), body: nil)
        guard case .hello(.accepted(_, let databasePath)) = reply else {
            return XCTFail("expected an accepted hello, got \(reply)")
        }
        XCTAssertEqual(databasePath, home.appendingPathComponent("graph.sqlite").path)

        let (second, secondOutput) = try launch()
        second.waitUntilExit()
        let secondText = String(decoding: secondOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(second.terminationStatus, 1)
        XCTAssertTrue(secondText.contains("already running"), secondText)
        // It never printed a banner, which means it never opened the first instance's graph.
        XCTAssertFalse(secondText.contains("Graph:"), secondText)

        client.close()
        server.terminate() // SIGTERM
        server.waitUntilExit()
        XCTAssertEqual(server.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }
}
