//
//  FrameStreamTests.swift
//  SemelTransportTests
//
//  Frames over a real Unix-domain socket in a temporary directory: a listener accepts one
//  connection, and each side wraps its end in a FrameStream. What is pinned: whole frames
//  arrive whole however the socket chunks them, order is kept, and a close reaches the
//  other side as a close.
//

import Foundation
import Network
import SemelProtocol
@testable import SemelTransport
import XCTest

final class FrameStreamTests: XCTestCase {

    private var directory: URL!
    private var socketPath: String!
    private var listener: SocketListener!
    private let serverQueue = DispatchQueue(label: "FrameStreamTests.server")
    private let clientQueue = DispatchQueue(label: "FrameStreamTests.client")

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: a Unix-domain socket path is limited to 103 bytes on macOS, and
        // NSTemporaryDirectory() alone uses most of that.
        directory = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("t.sock").path
        listener = SocketListener(path: socketPath, queue: serverQueue)
    }

    override func tearDown() {
        listener.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    /// Starts the listener and returns a stream for the first accepted connection.
    private func acceptOne() throws -> FrameStream {
        var accepted: FrameStream?
        let ready    = expectation(description: "listener ready")
        let arrived  = expectation(description: "connection accepted")
        listener.onConnection = { connection in
            accepted = FrameStream(connection: connection, queue: self.serverQueue)
            arrived.fulfill()
        }
        listener.start { result in
            if case .failure(let error) = result {
                XCTFail("listener failed: \(error)")
            }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
        let client = FrameStream(connection: NWConnection(to: .unix(path: socketPath), using: .tcp),
                                 queue: clientQueue)
        clientStream = client
        client.start()
        wait(for: [arrived], timeout: 5)
        return try XCTUnwrap(accepted)
    }

    private var clientStream: FrameStream?

    func test_aFrameArrivesWholeAndInOrder() throws {
        let server = try acceptOne()
        let received = expectation(description: "two frames")
        received.expectedFulfillmentCount = 2
        var frames: [Frame] = []
        server.onFrame = { frame in
            frames.append(frame)
            received.fulfill()
        }
        server.start()

        let first  = Frame(kind: .request, correlationID: 1, json: Data(#"{"a":1}"#.utf8), body: Data(repeating: 7, count: 100_000))
        let second = Frame(kind: .request, correlationID: 2, json: Data(#"{"b":2}"#.utf8))
        clientStream?.send(first)
        clientStream?.send(second)

        wait(for: [received], timeout: 5)
        XCTAssertEqual(frames, [first, second])
    }

    func test_aReplyComesBackTheOtherWay() throws {
        let server = try acceptOne()
        server.onFrame = { frame in
            server.send(Frame(kind: .response, correlationID: frame.correlationID, json: Data("{}".utf8)))
        }
        server.start()
        let replied = expectation(description: "reply")
        var reply: Frame?
        clientStream?.onFrame = { frame in
            reply = frame
            replied.fulfill()
        }

        clientStream?.send(Frame(kind: .request, correlationID: 9, json: Data("{}".utf8)))

        wait(for: [replied], timeout: 5)
        XCTAssertEqual(reply?.kind, .response)
        XCTAssertEqual(reply?.correlationID, 9)
    }

    func test_closingOneEndClosesTheOther() throws {
        let server = try acceptOne()
        let closed = expectation(description: "server saw close")
        server.onClose = { _ in closed.fulfill() }
        server.start()

        clientStream?.close()

        wait(for: [closed], timeout: 5)
    }

    func test_aBadFrameClosesTheStreamWithAFrameError() throws {
        let server = try acceptOne()
        let closed = expectation(description: "server saw close")
        var closeError: Error?
        server.onClose = { error in
            closeError = error
            closed.fulfill()
        }
        server.start()

        // A header with a version byte this build does not speak.
        var bytes = try FrameEncoder.encode(Frame(kind: .request, correlationID: 1, json: Data("{}".utf8)))
        bytes[0] = Frame.version + 1
        clientStream?.sendRaw(bytes)

        wait(for: [closed], timeout: 5)
        XCTAssertEqual(closeError as? FrameError, .unsupportedVersion(Frame.version + 1))
    }

    /// NWConnection traps on a path over the limit instead of failing; the check exists so
    /// neither side ever hands it one.
    func test_aPathOverTheLimitIsRefusedNotTrapped() {
        let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"

        XCTAssertThrowsError(try UnixSocketPath.check(long)) { error in
            XCTAssertEqual(error as? TransportError, .pathTooLong(path: long, length: long.utf8.count, limit: UnixSocketPath.maximumLength))
        }
        XCTAssertNoThrow(try UnixSocketPath.check(socketPath))
    }
}
