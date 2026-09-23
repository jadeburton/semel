// SocketConnection.swift
// semel
//
// SemelConnection over a Unix-domain socket. `send` is synchronous: it registers a waiter
// under the correlation ID, writes the frame, and parks on a semaphore until the reader
// delivers that ID's reply. Several threads may be parked at once, each on its own
// waiter, which is the shape the engine's cache role will need. Events go to `onEvent`
// on the reader's queue, as the in-process connection delivers them.

import Foundation
import Network
import SemelProtocol
import SemelTransport

/// `LocalizedError` as well as `CustomStringConvertible`: the interpreter prints
/// `localizedDescription`, and a Swift error that does not conform reaches the prompt as
/// "the operation couldn't be completed", a type name and a case number.
public enum ConnectionError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unavailable(path: String, underlying: String)
    case pathTooLong(path: String, length: Int, limit: Int)
    case closed
    case unexpectedFrame

    public var description: String {
        switch self {
        case .unavailable(let path, let underlying):
            return "no server at \(path) (\(underlying)); start one with `semelserv`"
        case .pathTooLong(let path, let length, let limit):
            return "socket path is \(length) bytes, over the \(limit)-byte limit: \(path)"
        case .closed:
            return "the connection to the server closed before it answered; the server has stopped, "
                 + "or it could not frame the reply — check that `semelserv` is still running and what it last printed"
        case .unexpectedFrame:
            return "the server sent a frame this client cannot place"
        }
    }

    public var errorDescription: String? { description }
}

public final class SocketConnection: SemelConnection {

    public var onEvent: ((Event) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    private final class Waiter {
        let semaphore = DispatchSemaphore(value: 0)
        var reply: Result<(Response, Data?), Error>?
    }

    private let stream: FrameStream
    private let lock = NSLock()
    private var eventHandler: ((Event) -> Void)?
    private var waiters: [UInt64: Waiter] = [:]
    private var nextCorrelationID: UInt64 = 1
    private var isClosed = false

    // MARK: - Connecting

    /// Opens the socket and waits until it is ready, or fails with the path so the user
    /// knows what to start. Nothing is sent; the caller sends `hello`.
    public static func connect(to path: String, timeout: TimeInterval = 5) throws -> SocketConnection {
        // Named on its own: an over-long path is a misconfiguration to correct, not a
        // server to start.
        do {
            try UnixSocketPath.check(path)
        } catch {
            throw ConnectionError.pathTooLong(path: path,
                                              length: path.utf8.count,
                                              limit: UnixSocketPath.maximumLength)
        }
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        let queue      = DispatchQueue(label: "semel.socket-connection")
        let ready      = DispatchSemaphore(value: 0)
        var failure: String?

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                failure = "\(error)"
                ready.signal()
            case .waiting(let error):
                // Not listening or refused. NWConnection would retry; a local daemon that
                // is not there now will not be there in a moment either.
                failure = "\(error)"
                ready.signal()
            case .setup, .preparing, .cancelled:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)

        // `failure` is written by the state handler, which runs on `queue`; read it there
        // so a timeout does not race a state change arriving at the same moment.
        let arrived = ready.wait(timeout: .now() + timeout)
        let reason  = queue.sync { failure }
        guard arrived == .success, reason == nil else {
            connection.cancel()
            throw ConnectionError.unavailable(path: path, underlying: reason ?? "timed out after \(Int(timeout)) s")
        }

        // The stream takes over the state handler from here.
        let socket = SocketConnection(stream: FrameStream(connection: connection, queue: queue))
        socket.stream.start()
        return socket
    }

    private init(stream: FrameStream) {
        self.stream = stream
        stream.onFrame = { [weak self] frame in self?.receive(frame) }
        stream.onClose = { [weak self] _ in self?.closeAll() }
    }

    public func close() {
        stream.close()
        closeAll()
    }

    // MARK: - SemelConnection

    public func send(_ request: Request, body: Data?) throws -> (Response, Data?) {
        // Encoded before the waiter is registered: a request that cannot be encoded must
        // leave no waiter behind for a reply that will never come.
        let json   = try MessageCoder.encode(request)
        let waiter = Waiter()
        let correlationID: UInt64 = try lock.withLock { () throws -> UInt64 in
            guard !isClosed else {
                throw ConnectionError.closed
            }
            defer { nextCorrelationID += 1 }
            waiters[nextCorrelationID] = waiter
            return nextCorrelationID
        }

        // A request too large to frame leaves no waiter behind for a reply that will never
        // come, the same way an unencodable request does not.
        do {
            try stream.send(Frame(kind: .request, correlationID: correlationID, json: json, body: body ?? Data()))
        } catch {
            lock.withLock { _ = waiters.removeValue(forKey: correlationID) }
            throw error
        }
        waiter.semaphore.wait()

        guard let reply = waiter.reply else {
            throw ConnectionError.closed
        }
        return try reply.get()
    }

    // MARK: - Receiving

    private func receive(_ frame: Frame) {
        switch frame.kind {
        case .response:
            let waiter = lock.withLock { waiters.removeValue(forKey: frame.correlationID) }
            guard let waiter else {
                // A reply nobody is waiting for: dropped, but said, because it means the
                // two sides disagree about what is in flight.
                FileHandle.standardError.write(Data("semel: dropped a reply for unknown request \(frame.correlationID)\n".utf8))
                return
            }
            do {
                let response = try frame.response()
                waiter.reply = .success((response, frame.body.isEmpty ? nil : frame.body))
            } catch {
                waiter.reply = .failure(error)
            }
            waiter.semaphore.signal()

        case .event:
            guard let event = try? frame.event() else {
                return
            }
            onEvent?(event)

        case .request:
            // The server does not send requests; nothing to do but note it.
            FileHandle.standardError.write(Data("semel: the server sent a request frame; ignored\n".utf8))
        }
    }

    /// Fails every waiter and refuses later sends. Idempotent.
    private func closeAll() {
        let orphans: [Waiter] = lock.withLock {
            isClosed = true
            let all = Array(waiters.values)
            waiters.removeAll()
            return all
        }
        for waiter in orphans {
            waiter.reply = .failure(ConnectionError.closed)
            waiter.semaphore.signal()
        }
    }
}
