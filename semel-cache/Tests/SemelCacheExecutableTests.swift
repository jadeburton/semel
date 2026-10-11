// SemelCacheExecutableTests.swift
// SemelCacheServerTests
//
// The binary, as an operator runs it: `serve` in the background over a test's home, then
// `status` and `purge` as processes of their own — through the running server, and on the
// home itself once the server has stopped.

import Foundation
import SemelCache
import SemelCacheServer
import SemelNodeKit
import SemelProtocol
import SemelTestSupport
import SemelTransport
import XCTest

final class SemelCacheExecutableTests: CacheServerTestCase {

    private var processes: [ManagedProcess] = []

    override func tearDown() {
        for process in processes where process.isRunning {
            process.terminate()
            _ = process.waitForExit(timeout: 10)
        }
        processes = []
        super.tearDown()
    }

    private var binary: URL {
        ProductsDirectory.executable(named: "semel-cache", besideBundleAt: Bundle(for: Self.self).bundleURL)
    }

    private func launch(_ arguments: [String]) throws -> ManagedProcess {
        let process = ManagedProcess(executable: binary, arguments: arguments, environment: [:])
        try process.start()
        processes.append(process)
        return process
    }

    /// Runs a command to its end: its status and what it printed.
    private func run(_ arguments: [String]) throws -> (status: Int32?, output: String) {
        let process = try launch(arguments)
        let status = process.waitForExit(timeout: 60)
        return (status, process.output)
    }

    /// A port nothing listens on now: bound and let go.
    private func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        XCTAssertTrue(bound, "fixture: a port to listen on")
        return UInt16(bigEndian: address.sin_port)
    }

    private func connectWhenListening(port: UInt16) throws -> SocketConnection {
        var lastError: Error?
        for _ in 0..<100 {
            do {
                return try SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: port), timeout: 1)
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw try XCTUnwrap(lastError)
    }

    func test_statusAndPurgeThroughTheRunningServerAndOnTheHomeOnceItStops() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path),
                          "semel-cache is not built beside the test bundle at \(binary.path)")
        let homePath = home.folder.path
        let port = try freePort()
        let server = try launch(["serve", "--home", homePath, "--listen", "127.0.0.1:\(port)", "--limit", "1G", "--writers", "all"])

        let client = try connectWhenListening(port: port)
        defer { client.close() }
        XCTAssertEqual(try client.send(.hello(Hello(role: .cache, wantsWrite: true)), body: nil).0,
                       .hello(.cacheAccepted(access: .readWrite)))
        for seed in ["kept", "poisoned"] {
            let item = object(seed)
            let body = entryBytes(seed)
            XCTAssertEqual(try client.send(.cache(.putObject(hash: item.hash)), body: item.bytes).0, .cache(.stored))
            XCTAssertEqual(try client.send(.cache(.putEntry(key: key(seed), cost: 5, objects: [item.hash], length: body.count)),
                                           body: body).0, .cache(.stored))
        }
        _ = try client.send(.cache(.getEntry(key: key("kept"))), body: nil)
        _ = try client.send(.cache(.getEntry(key: key("never put"))), body: nil)

        let running = try run(["status", "--home", homePath])
        XCTAssertEqual(running.status, 0, running.output)
        XCTAssertTrue(running.output.contains("answering at 127.0.0.1:\(port)"), running.output)
        XCTAssertTrue(running.output.contains("entries  2"), running.output)
        XCTAssertTrue(running.output.contains("hits     1 since the server started"), running.output)
        XCTAssertTrue(running.output.contains("misses   1 since the server started"), running.output)

        let purgedOne = try run(["purge", "--home", homePath, key("poisoned").hash])
        XCTAssertEqual(purgedOne.status, 0, purgedOne.output)
        XCTAssertTrue(purgedOne.output.contains("purged the entry under \(key("poisoned").hash)"), purgedOne.output)
        XCTAssertEqual(try client.send(.cache(.getEntry(key: key("poisoned"))), body: nil).0, .cache(.miss),
                       "the running server purged it from what it answers from")

        client.close()
        server.terminate()
        XCTAssertEqual(server.waitForExit(timeout: 30), 0, server.outputTail())
        XCTAssertTrue(server.output.contains("Writers: all"), server.output)

        let stopped = try run(["status", "--home", homePath])
        XCTAssertEqual(stopped.status, 0, stopped.output)
        XCTAssertTrue(stopped.output.contains("not running"), stopped.output)
        XCTAssertTrue(stopped.output.contains("entries  1"), stopped.output)

        let purgedAll = try run(["purge", "--home", homePath, "--all"])
        XCTAssertEqual(purgedAll.status, 0, purgedAll.output)
        XCTAssertTrue(purgedAll.output.contains("purged 1 entry and every object"), purgedAll.output)
        XCTAssertEqual(DataObjectStore(storeRoot: home.objectsFolder).objects(), [])

        let settings = try CacheServerConfiguration.read(from: home.configurationFile)
        XCTAssertEqual(settings.writers, .all, "serve wrote its arguments to the home")
        XCTAssertEqual(settings.limit, ByteCount.gibibytes(1))
    }

    func test_aMistypedCommandSaysWhatIsWrongAndHowToAsk() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path),
                          "semel-cache is not built beside the test bundle at \(binary.path)")

        let result = try run(["purge", "--home", home.folder.path, "abc"])

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.output.contains("'abc' is not a cache key"), result.output)
        XCTAssertTrue(result.output.contains("usage: semel-cache serve"), result.output)
    }
}
