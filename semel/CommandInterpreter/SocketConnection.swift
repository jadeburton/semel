// SocketConnection.swift
// semel
//
// SemelConnection over a Unix-domain socket. `send` is synchronous: it registers a waiter
// under the correlation ID, writes the frame, and parks on a semaphore until the reader
// delivers that ID's reply — each part of a streamed one, then the last. Several threads
// may be parked at once, each on its own waiter, which is the shape the engine's cache
// role will need. `sendWithoutWaiting` is the same two halves with the caller in between:
// the waiter is registered and the frame written, and the parking happens when the caller
// asks the handle for its reply. Events go to `onEvent` on the reader's queue, as the
// in-process connection delivers them.

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
            return "no server at \(path) (\(underlying))"
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

    /// One request in flight. The reader puts what arrives on `arrivals` and signals once
    /// per arrival; the collecting thread takes them in order, so a streamed reply's parts
    /// reach `onPart` there, one at a time, and the waiter is released only by the last
    /// frame or the connection closing (B-137). What arrives before anyone collects stays
    /// here until they do. Both fields are guarded by the connection's lock.
    private final class Waiter {
        enum Arrival {
            case part(Result<Response, Error>)
            case last(Result<(Response, Data?), Error>)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var arrivals: [Arrival] = []
        var reply: IncomingReply

        init(correlationID: UInt64) {
            reply = IncomingReply(correlationID: correlationID)
        }
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

    /// Whether requests can still be sent: false once the server has gone or `close` was
    /// called. A client that outlives one engine — `semel-watch` — asks this to know when
    /// to open the next connection.
    public var isOpen: Bool {
        lock.withLock { !isClosed }
    }

    // MARK: - SemelConnection

    public func send(_ request: Request, body: Data?, onPart: (Response) throws -> Void) throws -> (Response, Data?) {
        try collect(try dispatch(request, body: body), onPart: onPart)
    }

    /// The waiter is registered before the frame leaves, so the reply has somewhere to go
    /// however soon it comes; the caller collects it from there whenever it asks, and the
    /// parts of a streamed one wait in the waiter until then.
    public func sendWithoutWaiting(_ request: Request, body: Data?) throws -> PendingReply {
        let waiter = try dispatch(request, body: body)
        return PendingReply(collecting: { [self] in
            var parts = ReplyParts()
            let (last, replyBody) = try collect(waiter, onPart: { try parts.append($0) })
            return (try parts.whole(endingWith: last), replyBody)
        })
    }

    /// Registers a waiter for the request's reply and writes its frame, without waiting.
    private func dispatch(_ request: Request, body: Data?) throws -> Waiter {
        // Encoded before the waiter is registered: a request that cannot be encoded must
        // leave no waiter behind for a reply that will never come.
        let json = try MessageCoder.encode(request)
        let (correlationID, waiter) = try lock.withLock { () throws -> (UInt64, Waiter) in
            guard !isClosed else {
                throw ConnectionError.closed
            }
            defer { nextCorrelationID += 1 }
            let waiter = Waiter(correlationID: nextCorrelationID)
            waiters[nextCorrelationID] = waiter
            return (nextCorrelationID, waiter)
        }

        // A request too large to frame leaves no waiter behind for a reply that will never
        // come, the same way an unencodable request does not.
        do {
            try stream.send(Frame(kind: .request, correlationID: correlationID, json: json, body: body ?? Data()))
        } catch {
            lock.withLock { _ = waiters.removeValue(forKey: correlationID) }
            throw error
        }
        return waiter
    }

    /// Takes the waiter's arrivals in order, handing each part to `onPart`, until the last.
    private func collect(_ waiter: Waiter, onPart: (Response) throws -> Void) throws -> (Response, Data?) {
        var heldFailure: Error?
        while true {
            waiter.semaphore.wait()
            let arrival = lock.withLock { waiter.arrivals.removeFirst() }
            switch arrival {
            case .part(let part):
                guard heldFailure == nil else {
                    continue
                }
                do {
                    try onPart(try part.get())
                } catch {
                    heldFailure = error
                }
            case .last(let reply):
                if let heldFailure {
                    throw heldFailure
                }
                return try reply.get()
            }
        }
    }

    // MARK: - Receiving

    private func receive(_ frame: Frame) {
        switch frame.kind {
        case .response:
            // A part leaves its waiter registered for the frames still to come; the last
            // frame releases it. Read under the lock, so a close arriving from another
            // thread sees how many parts came.
            let waiter: Waiter? = lock.withLock {
                guard let waiter = frame.continues ? waiters[frame.correlationID]
                                                   : waiters.removeValue(forKey: frame.correlationID) else {
                    return nil
                }
                let arrival: Waiter.Arrival
                do {
                    switch try waiter.reply.receive(frame) {
                    case .part(let part):            arrival = .part(.success(part))
                    case .last(let last, let body):  arrival = .last(.success((last, body)))
                    }
                } catch {
                    arrival = frame.continues ? .part(.failure(error)) : .last(.failure(error))
                }
                waiter.arrivals.append(arrival)
                return waiter
            }
            guard let waiter else {
                // A reply nobody is waiting for: dropped, but said, because it means the
                // two sides disagree about what is in flight.
                FileHandle.standardError.write(Data("semel: dropped a reply for unknown request \(frame.correlationID)\n".utf8))
                return
            }
            waiter.semaphore.signal()

        case .event:
            // An event is one frame; a continuing one is the server's framing bug, read
            // as an event that cannot be decoded is.
            guard !frame.continues, let event = try? frame.event() else {
                return
            }
            onEvent?(event)

        case .request:
            // The server does not send requests; nothing to do but note it.
            FileHandle.standardError.write(Data("semel: the server sent a request frame; ignored\n".utf8))
        }
    }

    /// Fails every waiter and refuses later sends. Idempotent. A waiter whose reply had
    /// begun to stream is told it was cut short, not that nothing came: its caller may
    /// already have acted on the parts.
    private func closeAll() {
        let orphans: [Waiter] = lock.withLock {
            isClosed = true
            let all = Array(waiters.values)
            waiters.removeAll()
            for waiter in all {
                let failure: Error = waiter.reply.truncation ?? ConnectionError.closed
                waiter.arrivals.append(.last(.failure(failure)))
            }
            return all
        }
        for waiter in orphans {
            waiter.semaphore.signal()
        }
    }
}
