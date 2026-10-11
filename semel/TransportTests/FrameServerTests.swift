// FrameServerTests.swift
// SemelTransportTests
//
// The listening half of the transport with a service of the test's own: the same server
// over a Unix-domain socket and over TCP on localhost, several clients at once, a request
// that blocks answered off the queue the others are answered on, and events to the clients
// that asked for them. Nothing of the engine is here; that is the point of the split.

import Foundation
import SemelProtocol
import SemelTransport
import XCTest

final class FrameServerTests: XCTestCase {

    private var directory: URL!
    private var server: FrameServer?

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: a Unix-domain socket path is limited to 103 bytes on macOS.
        directory = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    /// A server whose every client is answered by an `EchoService`.
    private func startServer(at endpoint: Endpoint, services: ServiceLog = ServiceLog()) throws -> FrameServer {
        let started = FrameServer(endpoint: endpoint, name: "frame-server-tests") {
            services.make()
        }
        try started.start()
        server = started
        return started
    }

    private func hello(_ connection: SocketConnection) throws -> Response {
        try connection.send(.hello(Hello(role: .daemon)), body: nil).0
    }

    // MARK: - Two endpoints, one server

    func test_aClientIsAnsweredOverAUnixSocket() throws {
        let path = directory.appendingPathComponent("s.sock").path
        _ = try startServer(at: .unix(path: path))

        let client = try SocketConnection.connect(to: path)
        defer { client.close() }

        XCTAssertEqual(try hello(client), EchoService.helloReply)
    }

    func test_aClientIsAnsweredOverTCPOnLocalhost() throws {
        let listening = try startServer(at: .tcp(host: "127.0.0.1", port: 0))
        let port = try XCTUnwrap(listening.port, "a TCP server reports the port it was given")
        XCTAssertNotEqual(port, 0)

        let client = try SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: port))
        defer { client.close() }

        XCTAssertEqual(try hello(client), EchoService.helloReply)
        XCTAssertEqual(try client.send(.daemon(.collect), body: Data("echo".utf8)).1, Data("echo".utf8),
                       "a body travels both ways")
    }

    func test_twoTCPClientsAreAnsweredAtOnceEachWithAServiceOfItsOwn() throws {
        let services  = ServiceLog()
        let listening = try startServer(at: .tcp(host: "127.0.0.1", port: 0), services: services)
        let port      = try XCTUnwrap(listening.port)

        let first  = try SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: port))
        let second = try SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: port))
        defer {
            first.close()
            second.close()
        }

        XCTAssertEqual(try hello(first), EchoService.helloReply)
        XCTAssertEqual(try hello(second), EchoService.helloReply)
        XCTAssertEqual(listening.connectionCount, 2)
        XCTAssertEqual(services.count, 2)
    }

    func test_nothingListeningOnATCPPortIsUnavailableNamingIt() throws {
        let listening = try startServer(at: .tcp(host: "127.0.0.1", port: 0))
        let port = try XCTUnwrap(listening.port)
        listening.stop()

        XCTAssertThrowsError(try SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: port), timeout: 2)) { error in
            guard case .unavailable(let endpoint, _)? = error as? ConnectionError else {
                return XCTFail("expected unavailable, got \(error)")
            }
            XCTAssertEqual(endpoint, "127.0.0.1:\(port)")
        }
    }

    // MARK: - Answering

    /// A request that blocks is answered on a thread of its own: the client's next request,
    /// sent behind it, is answered while it waits.
    func test_aRequestThatBlocksDoesNotHoldUpTheOnesBehindIt() throws {
        let services  = ServiceLog()
        let listening = try startServer(at: .tcp(host: "127.0.0.1", port: 0), services: services)
        let client    = try SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: try XCTUnwrap(listening.port)))
        defer { client.close() }

        let blocked = try client.sendWithoutWaiting(.daemon(.wait), body: nil)
        XCTAssertEqual(try client.send(.daemon(.collect), body: nil).0, .daemon(.ok))

        services.release.signal()
        XCTAssertEqual(try blocked.reply().0, .daemon(.ok))
    }

    func test_anEventReachesOnlyTheClientsWhoseServiceReceivesEvents() throws {
        let services  = ServiceLog()
        let listening = try startServer(at: .tcp(host: "127.0.0.1", port: 0), services: services)
        let port      = try XCTUnwrap(listening.port)
        let listener  = try SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: port))
        let ignorer   = try SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: port))
        defer {
            listener.close()
            ignorer.close()
        }
        let heard   = expectation(description: "the subscribed client hears the event")
        let unheard = expectation(description: "the other client hears nothing")
        unheard.isInverted = true
        listener.onEvent = { _ in heard.fulfill() }
        ignorer.onEvent  = { _ in unheard.fulfill() }

        _ = try listener.send(.daemon(.subscribe), body: nil)
        _ = try hello(ignorer)
        listening.deliver(.daemon(.notice(line: "hello")))

        wait(for: [heard, unheard], timeout: 1)
    }

    func test_eachServiceIsToldWhenItsClientHasGone() throws {
        let services  = ServiceLog()
        let listening = try startServer(at: .tcp(host: "127.0.0.1", port: 0), services: services)
        let client    = try SocketConnection.connect(to: .tcp(host: "127.0.0.1", port: try XCTUnwrap(listening.port)))
        _ = try hello(client)

        client.close()

        let deadline = Date().addingTimeInterval(5)
        while services.ended < 1, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(services.ended, 1)
        XCTAssertEqual(listening.connectionCount, 0)
    }

    // MARK: - The socket file

    func test_aSecondServerAtAnsweredPathIsRefused() throws {
        let path = directory.appendingPathComponent("s.sock").path
        _ = try startServer(at: .unix(path: path))

        XCTAssertThrowsError(try FrameServer.claimSocket(at: path)) { error in
            XCTAssertEqual(error as? FrameServerError, .alreadyAnswered(path: path))
        }
    }

    func test_stoppingRemovesTheSocketFileItCreated() throws {
        let path = directory.appendingPathComponent("s.sock").path
        let listening = try startServer(at: .unix(path: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        listening.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}

// MARK: - A service of the test's own

/// Counts the services the server made and the clients that ended, and holds the release a
/// blocking request waits for.
private final class ServiceLog {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var made = 0
    private var endedCount = 0

    var count: Int { lock.withLock { made } }
    var ended: Int { lock.withLock { endedCount } }

    func make() -> EchoService {
        lock.withLock { made += 1 }
        return EchoService(log: self)
    }

    func noteEnded() {
        lock.withLock { endedCount += 1 }
    }
}

/// Answers `hello` as accepted, `wait` once the log releases it, `subscribe` by receiving
/// events from then on, and anything else with `ok` and the body it came with.
private final class EchoService: ConnectionService {

    static let helloReply = Response.hello(.accepted(serverVersion: "test", databasePath: "none"))

    private let log: ServiceLog
    private let lock = NSLock()
    private var subscribed = false

    init(log: ServiceLog) {
        self.log = log
    }

    var receivesEvents: Bool {
        lock.withLock { subscribed }
    }

    func prepare(_ request: Request, body: Data?) -> PreparedAnswer {
        switch request {
        case .hello:
            return PreparedAnswer(blocks: false) { _ in (Self.helloReply, nil) }
        case .daemon(.wait):
            return PreparedAnswer(blocks: true) { [log] _ in
                log.release.wait()
                return (.daemon(.ok), nil)
            }
        case .daemon(.subscribe):
            return PreparedAnswer(blocks: false) { [self] _ in
                lock.withLock { subscribed = true }
                return (.daemon(.ok), nil)
            }
        case .daemon:
            return PreparedAnswer(blocks: false) { _ in (.daemon(.ok), body) }
        }
    }

    func connectionEnded() {
        log.noteEnded()
    }
}
