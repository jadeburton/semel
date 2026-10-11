// CacheServerLatencyTests.swift
// SemelCacheServerTests
//
// How quickly the server answers, over TCP on localhost with a warm index: each request
// kind's latency, and the throughput of one client putting a build's worth of entries. Run
// on demand, not in CI, because a figure is a measurement of the machine as much as of the
// code:
//
//     SEMEL_CACHE_BENCHMARK=1 scripts/build.sh test --filter CacheServerLatencyTests
//
// With `SEMEL_CACHE_BENCHMARK_SERVER` naming a `semel-cache` binary — a release build — the
// figures are that binary's, run over a home of the test's; without it, the server is this
// test's own debug build, in process.

import Foundation
import SemelCache
import SemelCacheServer
import SemelNodeKit
import SemelProtocol
import SemelTestSupport
import SemelTransport
import XCTest

final class CacheServerLatencyTests: CacheServerTestCase {

    private var external: ManagedProcess?

    override func tearDown() {
        if let external, external.isRunning {
            external.terminate()
            _ = external.waitForExit(timeout: 10)
        }
        external = nil
        super.tearDown()
    }

    /// A server over the test's home: the named binary, or one in process.
    private func startServer() throws -> (port: UInt16, stop: () -> Void) {
        guard let path = ProcessInfo.processInfo.environment["SEMEL_CACHE_BENCHMARK_SERVER"] else {
            let server = try CacheServer(home: home, overrides: CacheServerConfiguration(listen: CacheListenAddress(host: "127.0.0.1", port: 0),
                                                                                         limit: ByteCount.gibibytes(20),
                                                                                         writers: .all))
            try server.start()
            return (try XCTUnwrap(server.port), { server.stop() })
        }
        let port = UInt16.random(in: 40_000...60_000)
        let process = ManagedProcess(executable: URL(fileURLWithPath: path),
                                     arguments: ["serve", "--home", home.folder.path, "--listen", "127.0.0.1:\(port)",
                                                 "--limit", "20G", "--writers", "all"],
                                     environment: [:])
        try process.start()
        external = process
        return (port, {
            process.terminate()
            _ = process.waitForExit(timeout: 30)
        })
    }

    private func connect(_ port: UInt16) throws -> SocketConnection {
        for _ in 0..<100 {
            if let connection = try? SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: port), timeout: 1) {
                _ = try connection.send(.hello(Hello(role: .cache, wantsWrite: true)), body: nil)
                return connection
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CacheAdministrationError.serverUnreachable(address: "127.0.0.1:\(port)", reason: "never listened")
    }

    /// Median and 99th percentile of `count` round trips of `request`, in microseconds.
    private func measure(_ name: String, count: Int, _ request: (Int) throws -> Void) rethrows -> String {
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let start = DispatchTime.now().uptimeNanoseconds
            try request(index)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let tail   = samples[min(samples.count - 1, samples.count * 99 / 100)]
        return "\(name): median \(String(format: "%.0f", median)) µs, p99 \(String(format: "%.0f", tail)) µs (\(count) requests)"
    }

    /// Requests per second of `count` requests sent without waiting, then collected.
    private func pipelined(_ name: String, count: Int, _ send: (Int) throws -> PendingReply) throws -> String {
        let start = DispatchTime.now().uptimeNanoseconds
        let replies = try (0..<count).map(send)
        for reply in replies {
            _ = try reply.reply()
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return "\(name), pipelined: \(String(format: "%.0f", Double(count) / seconds)) requests/s (\(count) requests)"
    }

    func test_latencyOfEachRequestAndThroughputOfABuildsWorthOfPuts() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SEMEL_CACHE_BENCHMARK"] == "1",
                          "a measurement, run on demand: SEMEL_CACHE_BENCHMARK=1")
        let (port, stop) = try startServer()
        defer { stop() }
        let client = try connect(port)
        defer { client.close() }
        var report: [String] = []

        // Throughput: 1,000 entries holding 10,000 objects of 4 KB, pipelined as an engine's
        // population queue would send them — every object, then every entry.
        let objects = (0..<10_000).map { object("throughput \($0)", count: 4_096) }
        let started = DispatchTime.now().uptimeNanoseconds
        var pending: [PendingReply] = []
        for item in objects {
            pending.append(try client.sendWithoutWaiting(.cache(.putObject(hash: item.hash)), body: item.bytes))
        }
        for index in 0..<1_000 {
            let body = entryBytes("throughput entry \(index)")
            let held = objects[(index * 10)..<(index * 10 + 10)].map(\.hash)
            pending.append(try client.sendWithoutWaiting(.cache(.putEntry(key: key("throughput \(index)"), cost: 100,
                                                                          objects: held, length: body.count)),
                                                         body: body))
        }
        for reply in pending {
            XCTAssertEqual(try reply.reply().0, .cache(.stored))
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        report.append("throughput: 1,000 entries with 10,000 objects of 4 KB in \(String(format: "%.2f", seconds)) s "
                    + "(\(String(format: "%.0f", 11_000 / seconds)) requests/s, "
                    + "\(String(format: "%.1f", Double(10_000 * 4_096) / seconds / 1_048_576)) MB/s)")

        // Latency, one request at a time, over the warm index just written — once the files
        // of those objects, written behind the answers, have landed and the server is idle.
        // A measurement's pause, not something the server waits for.
        _ = try client.send(.cache(.status), body: nil)
        Thread.sleep(forTimeInterval: 3)
        report.append(try measure("getEntry hit", count: 1_000) { index in
            XCTAssertEqual(try client.send(.cache(.getEntry(key: key("throughput \(index)"))), body: nil).0, .cache(.entry(cost: 100)))
        })
        report.append(try measure("getEntry miss", count: 1_000) { index in
            XCTAssertEqual(try client.send(.cache(.getEntry(key: key("absent \(index)"))), body: nil).0, .cache(.miss))
        })
        let hundred = objects.prefix(100).map(\.hash)
        report.append(try measure("hasObjects, 100 hashes", count: 1_000) { _ in
            XCTAssertEqual(try client.send(.cache(.hasObjects(hashes: hundred)), body: nil).0, .cache(.missingObjects(hashes: [])))
        })
        let megabytes = (0..<100).map { object("megabyte \($0)", count: 1_048_576) }
        report.append(try measure("putObject, 1 MB", count: megabytes.count) { index in
            XCTAssertEqual(try client.send(.cache(.putObject(hash: megabytes[index].hash)), body: megabytes[index].bytes).0,
                           .cache(.stored))
        })
        report.append(try measure("getObject, 1 MB", count: megabytes.count) { index in
            let (reply, body) = try client.send(.cache(.getObject(hash: megabytes[index].hash)), body: nil)
            XCTAssertEqual(reply, .cache(.object))
            XCTAssertEqual(body?.count, 1_048_576)
        })

        // Ceilings, pipelined: what one connection carries when the store does next to
        // nothing (a miss), and when every request writes a small object.
        report.append(try pipelined("getEntry misses", count: 10_000) { index in
            try client.sendWithoutWaiting(.cache(.getEntry(key: key("ceiling \(index)"))), body: nil)
        })
        let small = (0..<5_000).map { object("ceiling object \($0)", count: 4_096) }
        report.append(try pipelined("putObject, 4 KB", count: small.count) { index in
            try client.sendWithoutWaiting(.cache(.putObject(hash: small[index].hash)), body: small[index].bytes)
        })

        let text = report.joined(separator: "\n")
        print("semel-cache over TCP on localhost:\n" + text)
        add(XCTAttachment(string: text))
    }
}
