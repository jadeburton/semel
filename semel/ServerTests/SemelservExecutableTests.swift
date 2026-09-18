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
import SemelTestSupport
import XCTest

final class SemelservExecutableTests: XCTestCase {

    private var home: URL!
    private var socketPath: String!
    private var processes: [ManagedProcess] = []

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
            _ = process.waitForExit(timeout: 10)
        }
        processes = []
        try? FileManager.default.removeItem(at: home)
        home = nil
        super.tearDown()
    }

    private var binary: URL {
        ProductsDirectory.executable(named: "semelserv", besideBundleAt: Bundle(for: Self.self).bundleURL)
    }

    private func launch() throws -> ManagedProcess {
        let process = ManagedProcess(executable: binary, arguments: [],
                                     environment: ["SEMEL_HOME": home.path, "SEMEL_SOCKET": socketPath])
        try process.start()
        processes.append(process)
        return process
    }

    func test_startsAnswersHelloRefusesASecondInstanceAndStopsOnSigterm() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path),
                          "semelserv is not built beside the test bundle at \(binary.path)")

        let server = try launch()
        XCTAssertTrue(SocketWait.wait(forSocketAt: socketPath), "the server never created \(socketPath!)")

        let client = try SocketConnection.connect(to: socketPath)
        let (reply, _) = try client.send(.hello(Hello(role: .daemon)), body: nil)
        guard case .hello(.accepted(_, let databasePath)) = reply else {
            return XCTFail("expected an accepted hello, got \(reply)")
        }
        XCTAssertEqual(databasePath, home.appendingPathComponent("graph.sqlite").path)

        let second = try launch()
        XCTAssertEqual(second.waitForExit(timeout: 30), 1)
        let secondText = second.output
        XCTAssertTrue(secondText.contains("already running"), secondText)
        // It never printed a banner, which means it never opened the first instance's graph.
        XCTAssertFalse(secondText.contains("Graph:"), secondText)

        client.close()
        server.terminate() // SIGTERM
        XCTAssertEqual(server.waitForExit(timeout: 30), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }
}
