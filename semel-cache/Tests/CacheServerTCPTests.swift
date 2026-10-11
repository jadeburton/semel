// CacheServerTCPTests.swift
// SemelCacheServerTests
//
// The server as a client meets it: a home, a TCP listener on localhost, and connections
// from `SemelTransport`, two at once — one writing while the other reads.

import Foundation
import SemelCache
import SemelCacheServer
import SemelNodeKit
import SemelProtocol
import SemelTransport
import XCTest

final class CacheServerTCPTests: CacheServerTestCase {

    private func startServer(writers: CacheWriters) throws -> (CacheServer, UInt16) {
        let server = try CacheServer(home: home, overrides: CacheServerConfiguration(listen: CacheListenAddress(host: "127.0.0.1", port: 0),
                                                                                     writers: writers))
        try server.start()
        return (server, try XCTUnwrap(server.port))
    }

    private func connect(_ port: UInt16, wantsWrite: Bool) throws -> SocketConnection {
        let connection = try SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: port))
        _ = try connection.send(.hello(Hello(role: .cache, wantsWrite: wantsWrite)), body: nil)
        return connection
    }

    func test_twoClientsAtOnceOneWritingWhileTheOtherReads() throws {
        let (server, port) = try startServer(writers: .all)
        defer { server.stop() }
        let writer = try connect(port, wantsWrite: true)
        let reader = try connect(port, wantsWrite: false)
        defer {
            writer.close()
            reader.close()
        }
        let count = 50
        let objects = (0..<count).map { object("object \($0)", count: 2_000) }

        let wrote = expectation(description: "the writer put every entry")
        DispatchQueue.global().async { [self] in
            for (index, item) in objects.enumerated() {
                let body = entryBytes("entry \(index)")
                guard (try? writer.send(.cache(.putObject(hash: item.hash)), body: item.bytes).0) == .cache(.stored),
                      (try? writer.send(.cache(.putEntry(key: key("entry \(index)"), cost: index, objects: [item.hash],
                                                         length: body.count)), body: body).0) == .cache(.stored) else {
                    XCTFail("put \(index) was not stored")
                    break
                }
            }
            wrote.fulfill()
        }
        // Meanwhile the reader asks, and is answered whatever the writer has got to.
        var answered = 0
        for index in 0..<count {
            let (reply, _) = try reader.send(.cache(.getEntry(key: key("entry \(index)"))), body: nil)
            XCTAssertTrue(reply == .cache(.miss) || reply == .cache(.entry(cost: index)), "\(reply)")
            answered += 1
        }
        wait(for: [wrote], timeout: 60)

        XCTAssertEqual(answered, count)
        for index in [0, count / 2, count - 1] {
            let (reply, body) = try reader.send(.cache(.getEntry(key: key("entry \(index)"))), body: nil)
            XCTAssertEqual(reply, .cache(.entry(cost: index)))
            XCTAssertEqual(body, entryBytes("entry \(index)"))
        }
        let (objectReply, objectBody) = try reader.send(.cache(.getObject(hash: objects[7].hash)), body: nil)
        XCTAssertEqual(objectReply, .cache(.object))
        XCTAssertEqual(objectBody, objects[7].bytes)
        XCTAssertEqual(server.store.status().entries, count)
    }

    /// The listener's hello is the cache's: a read-only server says so to a client that
    /// asked to write, and refuses its writes on the wire.
    func test_aServerWithNoWritersAcceptsAWriterAsReadOnly() throws {
        let (server, port) = try startServer(writers: .none)
        defer { server.stop() }
        let client = try SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: port))
        defer { client.close() }

        XCTAssertEqual(try client.send(.hello(Hello(role: .cache, wantsWrite: true)), body: nil).0,
                       .hello(.cacheAccepted(access: .readOnly)))
        let item = object("item")
        XCTAssertEqual(try client.send(.cache(.putObject(hash: item.hash)), body: item.bytes).0,
                       .cache(.refused(reason: .readOnly)))
    }

    /// A second server on one home is refused before it opens anything.
    func test_aSecondServerOnTheSameHomeIsRefused() throws {
        let (server, _) = try startServer(writers: .all)
        defer { server.stop() }

        XCTAssertThrowsError(try CacheServer(home: home, overrides: CacheServerConfiguration())) { error in
            XCTAssertEqual(error as? CacheServerError, .alreadyRunning(home: home.folder.path))
        }
    }
}
