// SocketRemoteCacheTests.swift
// SemelCacheServerTests
//
// B-153, phase 3. The engine's way to a shared cache over TCP — `SocketRemoteCache`, the
// one conformance of `RemoteCache` that speaks frames — against a real `semel-cache` server
// on localhost: what it is granted, the requests a write and a fetch make, and how each way
// of failing reaches the client, which is what decides whether it keeps the connection.

import Foundation
import SemelCache
import SemelCacheClient
import SemelCacheServer
import SemelNodeKit
import SemelProtocol
import XCTest

final class SocketRemoteCacheTests: CacheServerTestCase {

    private func startServer(writers: CacheWriters) throws -> (CacheServer, CacheAddress) {
        let server = try CacheServer(home: home, overrides: CacheServerConfiguration(listen: CacheAddress(host: "127.0.0.1", port: 0),
                                                                                     writers: writers))
        try server.start()
        return (server, CacheAddress(host: "127.0.0.1", port: try XCTUnwrap(server.port)))
    }

    func test_aWriterPutsAnEntryAndAReaderFetchesItWithItsObjects() throws {
        let (server, address) = try startServer(writers: .all)
        defer { server.stop() }
        let writer = SocketRemoteCache(server: address)
        let reader = SocketRemoteCache(server: address)
        defer {
            writer.disconnect()
            reader.disconnect()
        }
        let item = object("object file", count: 4_000)

        XCTAssertEqual(try writer.connect(identity: "ci"), .readWrite)
        XCTAssertEqual(try writer.missingObjects(among: [item.hash]), [item.hash])
        try writer.putObject(hash: item.hash, bytes: item.bytes)
        try writer.putEntry(key: key("a"), cost: 250, objects: [item.hash], content: entryBytes("a"))

        XCTAssertEqual(try reader.connect(identity: nil), .readWrite, "a server whose writers are everyone grants every asker")
        let entry = try XCTUnwrap(try reader.entry(forKey: key("a")))
        XCTAssertEqual(entry, RemoteEntry(content: entryBytes("a"), cost: 250, objects: held(item)))
        XCTAssertEqual(try reader.missingObjects(among: [item.hash]), [])
        XCTAssertEqual(try reader.object(hash: item.hash, expectedBytes: item.bytes.count), item.bytes)
        XCTAssertNil(try reader.entry(forKey: key("absent")))
        XCTAssertNil(try reader.object(hash: object("absent").hash, expectedBytes: 100))
    }

    /// A server that lets nobody write grants read-only, and refuses a put without closing
    /// the connection: the refusal is about the request, not the link.
    func test_aReadOnlyGrantRefusesAWriteAndKeepsTheConnection() throws {
        let (server, address) = try startServer(writers: .none)
        defer { server.stop() }
        let client = SocketRemoteCache(server: address)
        defer { client.disconnect() }
        let item = object("object file")

        XCTAssertEqual(try client.connect(identity: "laptop"), .readOnly)
        XCTAssertThrowsError(try client.putObject(hash: item.hash, bytes: item.bytes)) { error in
            guard case .refused = error as? RemoteCacheError else {
                return XCTFail("expected a refusal, got \(error)")
            }
            XCTAssertFalse((error as? RemoteCacheError)?.endsConnection ?? true)
        }
        XCTAssertNil(try client.entry(forKey: key("a")), "the connection still answers")
    }

    func test_nothingListeningIsUnreachable() throws {
        let (server, address) = try startServer(writers: .all)
        server.stop()
        let client = SocketRemoteCache(server: address, connectTimeout: 2, requestDeadline: 2)

        XCTAssertThrowsError(try client.connect(identity: nil)) { error in
            guard case .unreachable = error as? RemoteCacheError else {
                return XCTFail("expected unreachable, got \(error)")
            }
        }
    }

    /// The server stopping closes the connection; the next request says so, as a failure
    /// that ends the connection.
    func test_aServerThatStopsEndsTheConnection() throws {
        let (server, address) = try startServer(writers: .all)
        let client = SocketRemoteCache(server: address)
        defer { client.disconnect() }
        XCTAssertEqual(try client.connect(identity: nil), .readWrite)

        server.stop()

        XCTAssertThrowsError(try client.entry(forKey: key("a"))) { error in
            guard case .connectionLost = error as? RemoteCacheError else {
                return XCTFail("expected the connection lost, got \(error)")
            }
            XCTAssertTrue((error as? RemoteCacheError)?.endsConnection ?? false)
        }
    }

    /// A server that takes the connection and never answers — a machine gone to sleep —
    /// costs one bounded wait, and the connection is given up.
    func test_aServerThatNeverAnswersIsGivenUpAfterTheDeadline() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(listener, generic, length) == 0 && getsockname(listener, generic, &length) == 0
                    && listen(listener, 4) == 0
            }
        }
        XCTAssertTrue(listening)
        let port = UInt16(bigEndian: address.sin_port)
        let client = SocketRemoteCache(server: CacheAddress(host: "127.0.0.1", port: port), connectTimeout: 2, requestDeadline: 0.5)
        let started = Date()

        XCTAssertThrowsError(try client.connect(identity: nil)) { error in
            XCTAssertEqual(error as? RemoteCacheError, .connectionLost(reason: "no answer within 0.5 s"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func test_aClientNeverConnectedHasNoConnectionToAsk() {
        let client = SocketRemoteCache(server: CacheAddress(host: "127.0.0.1", port: 1))

        XCTAssertThrowsError(try client.entry(forKey: key("a"))) { error in
            XCTAssertEqual(error as? RemoteCacheError, .connectionLost(reason: "no connection is open"))
        }
    }
}
