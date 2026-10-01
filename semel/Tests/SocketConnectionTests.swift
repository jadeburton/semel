//
//  SocketConnectionTests.swift
//  SemelCLITests
//
//  The client's socket connection against a tiny listener that answers from a script:
//  replies reach the caller that sent the request even when two are waiting, events
//  reach onEvent, and a closed socket fails every waiter instead of hanging it.
//

import Foundation
import Network
@testable import SemelCLI
import SemelProtocol
import SemelTransport
import XCTest

final class SocketConnectionTests: XCTestCase {

    private var directory: URL!
    private var socketPath: String!
    private var listener: SocketListener!
    private var serverStream: FrameStream?
    private let serverQueue = DispatchQueue(label: "SocketConnectionTests.server")

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Short on purpose: a Unix-domain socket path is limited to 103 bytes on macOS.
        directory = URL(fileURLWithPath: "/tmp/semel-tests/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("s.sock").path
    }

    override func tearDown() {
        listener?.cancel()
        listener = nil
        serverStream = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    /// Starts a listener whose one connection answers each request frame with `answer`.
    private func startServer(answer: @escaping (Frame) -> Frame?) {
        listener = SocketListener(path: socketPath, queue: serverQueue)
        let ready = expectation(description: "listener ready")
        listener.onConnection = { connection in
            let stream = FrameStream(connection: connection, queue: self.serverQueue)
            stream.onFrame = { frame in
                if let reply = answer(frame) {
                    try? stream.send(reply)
                }
            }
            stream.start()
            self.serverStream = stream
        }
        listener.start { _ in ready.fulfill() }
        wait(for: [ready], timeout: 5)
    }

    func test_aReplyReachesItsCaller() throws {
        startServer { frame in
            try? Frame.response(.daemon(.ok), correlationID: frame.correlationID)
        }
        let connection = try SocketConnection.connect(to: socketPath)

        let (response, body) = try connection.send(.daemon(.reset(clearCache: false)), body: nil)

        XCTAssertEqual(response, .daemon(.ok))
        XCTAssertNil(body)
    }

    func test_aReplyBodyComesBackAndAnEmptyOneIsNil() throws {
        startServer { frame in
            let request = try? frame.request()
            if case .daemon(.fetch(_, let path)) = request, path == "full" {
                return try? Frame.response(.daemon(.fetch(mode: 0o644)), correlationID: frame.correlationID, body: Data("bytes".utf8))
            }
            return try? Frame.response(.daemon(.fetch(mode: 0o644)), correlationID: frame.correlationID)
        }
        let connection = try SocketConnection.connect(to: socketPath)

        let (_, full)  = try connection.send(.daemon(.fetch(fileSystem: .input, path: "full")), body: nil)
        let (_, empty) = try connection.send(.daemon(.fetch(fileSystem: .input, path: "empty")), body: nil)

        XCTAssertEqual(full, Data("bytes".utf8))
        XCTAssertNil(empty)
    }

    /// Two threads wait at once; the server answers the second request first. Each caller
    /// must still get its own reply.
    func test_twoWaitingCallersEachGetTheirOwnReply() throws {
        var pending: [Frame] = []
        startServer { frame in
            pending.append(frame)
            guard pending.count == 2 else {
                return nil
            }
            // Answer in reverse order, on the server's queue.
            for waiting in pending.reversed() {
                let request = try? waiting.request()
                let text: String
                if case .daemon(.list(_, let pattern)) = request {
                    text = pattern
                } else {
                    text = "?"
                }
                if let reply = try? Frame.response(.daemon(.debug), correlationID: waiting.correlationID,
                                                   body: Data(text.utf8)) {
                    try? self.serverStream?.send(reply)
                }
            }
            return nil
        }
        let connection = try SocketConnection.connect(to: socketPath)
        let group = DispatchGroup()
        var results: [String: String] = [:]
        let lock = NSLock()

        for pattern in ["first", "second"] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if let (_, body) = try? connection.send(.daemon(.list(fileSystem: .input, pattern: pattern)), body: nil) {
                    lock.withLock { results[pattern] = String(decoding: body ?? Data(), as: UTF8.self) }
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results["first"],  "first")
        XCTAssertEqual(results["second"], "second")
    }

    func test_anEventReachesOnEvent() throws {
        startServer { frame in
            if let event = try? Frame.event(.daemon(.notice(line: "built"))) {
                try? self.serverStream?.send(event)
            }
            return try? Frame.response(.daemon(.ok), correlationID: frame.correlationID)
        }
        let connection = try SocketConnection.connect(to: socketPath)
        let delivered = expectation(description: "event")
        var events: [Event] = []
        connection.onEvent = { event in
            events.append(event)
            delivered.fulfill()
        }

        _ = try connection.send(.daemon(.subscribe), body: nil)

        wait(for: [delivered], timeout: 5)
        XCTAssertEqual(events, [.daemon(.notice(line: "built"))])
    }

    // MARK: - Streamed replies (B-137)

    /// Frames for a streamed `remove`: a part per path in `parts`, then `last` unmarked.
    private func streamedRemoval(parts: [String], last: [String], correlationID: UInt64) -> [Frame] {
        let partFrames = parts.compactMap { path in
            try? Frame.response(.daemon(.remove(removedFiles: [path], removedFolders: [])),
                                correlationID: correlationID, continues: true)
        }
        let lastFrame = try? Frame.response(.daemon(.remove(removedFiles: last, removedFolders: [])),
                                            correlationID: correlationID)
        return partFrames + [lastFrame].compactMap { $0 }
    }

    /// Parts reach `onPart` in order, the waiter is released only by the last frame, and
    /// the whole-reply `send` joins them.
    func test_partsReachTheCallerInOrderAndTheLastFrameEndsTheReply() throws {
        startServer { frame in
            for reply in self.streamedRemoval(parts: ["a", "b", "c"], last: ["d"], correlationID: frame.correlationID) {
                try? self.serverStream?.send(reply)
            }
            return nil
        }
        let connection = try SocketConnection.connect(to: socketPath)
        var parts: [Response] = []

        let (last, _) = try connection.send(.daemon(.remove(pattern: "*")), body: nil) { parts.append($0) }
        let (whole, _) = try connection.send(.daemon(.remove(pattern: "*")), body: nil)

        XCTAssertEqual(parts, ["a", "b", "c"].map { .daemon(.remove(removedFiles: [$0], removedFolders: [])) })
        XCTAssertEqual(last, .daemon(.remove(removedFiles: ["d"], removedFolders: [])))
        XCTAssertEqual(whole, .daemon(.remove(removedFiles: ["a", "b", "c", "d"], removedFolders: [])))
    }

    /// Two streams in flight at once, their frames interleaved on the wire: each caller
    /// gets its own parts, in its own order.
    func test_interleavedStreamsReachTheirOwnCallers() throws {
        var pending: [Frame] = []
        startServer { frame in
            pending.append(frame)
            guard pending.count == 2 else {
                return nil
            }
            let first  = self.streamedRemoval(parts: ["1a", "1b"], last: ["1c"], correlationID: pending[0].correlationID)
            let second = self.streamedRemoval(parts: ["2a", "2b"], last: ["2c"], correlationID: pending[1].correlationID)
            for (fromFirst, fromSecond) in zip(first, second) {
                try? self.serverStream?.send(fromSecond)
                try? self.serverStream?.send(fromFirst)
            }
            return nil
        }
        let connection = try SocketConnection.connect(to: socketPath)
        let group   = DispatchGroup()
        let lock    = NSLock()
        var results: [String: Response] = [:]

        for pattern in ["1", "2"] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                if let (whole, _) = try? connection.send(.daemon(.remove(pattern: pattern)), body: nil) {
                    lock.withLock { results[pattern] = whole }
                }
            }
            // The server pairs the requests in arrival order.
            Thread.sleep(forTimeInterval: 0.1)
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results["1"], .daemon(.remove(removedFiles: ["1a", "1b", "1c"], removedFolders: [])))
        XCTAssertEqual(results["2"], .daemon(.remove(removedFiles: ["2a", "2b", "2c"], removedFolders: [])))
    }

    /// A connection that closes after a part and before the last frame: the caller hears
    /// that the reply was cut short, naming how much came — not that nothing came, and
    /// never the part as though it were the answer.
    func test_aStreamCutShortByAClosingConnectionIsReportedAsTruncated() throws {
        startServer { frame in
            self.streamedRemoval(parts: ["a"], last: [], correlationID: frame.correlationID).first
        }
        let connection = try SocketConnection.connect(to: socketPath)

        // Closed once the part has arrived, so the part cannot be lost to the close.
        XCTAssertThrowsError(try connection.send(.daemon(.remove(pattern: "*")), body: nil) { _ in
            self.serverStream?.close()
        }) { error in
            guard case .truncated(_, let partsReceived)? = error as? ReplyStreamError else {
                return XCTFail("expected a truncated stream, got \(error)")
            }
            XCTAssertEqual(partsReceived, 1)
        }
    }

    func test_aClosedSocketFailsTheWaiterAndLaterSends() throws {
        startServer { _ in
            self.serverStream?.close()
            return nil
        }
        let connection = try SocketConnection.connect(to: socketPath)

        XCTAssertThrowsError(try connection.send(.daemon(.reset(clearCache: false)), body: nil)) { error in
            XCTAssertEqual(error as? ConnectionError, .closed)
        }
        XCTAssertThrowsError(try connection.send(.daemon(.reset(clearCache: false)), body: nil)) { error in
            XCTAssertEqual(error as? ConnectionError, .closed)
        }
    }

    /// B-94. The interpreter prints `localizedDescription`, which for a Swift error that
    /// says nothing about itself is "the operation couldn't be completed … error 2". Every
    /// case here has to reach the user as words, and a closed connection has to name what
    /// to look at.
    func test_aConnectionFailureReachesTheUserAsWords() {
        let closed = ConnectionError.closed.localizedDescription

        XCTAssertTrue(closed.contains("closed before it answered"), closed)
        XCTAssertTrue(closed.contains("semelserv"), closed)
        XCTAssertFalse(closed.contains("error 2"), closed)

        let unavailable = ConnectionError.unavailable(path: "/tmp/s.sock", underlying: "refused").localizedDescription
        XCTAssertTrue(unavailable.contains("/tmp/s.sock"), unavailable)
    }

    func test_connectingToNothingFailsWithThePath() {
        XCTAssertThrowsError(try SocketConnection.connect(to: socketPath, timeout: 2)) { error in
            guard case .unavailable(let path, _)? = error as? ConnectionError else {
                return XCTFail("expected unavailable, got \(error)")
            }
            XCTAssertEqual(path, socketPath)
        }
    }
}
