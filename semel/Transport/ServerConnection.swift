// ServerConnection.swift
// SemelTransport
//
// One client of a server. A FrameStream, the service that answers this client's requests,
// and three serial queues of its own: the stream's, which reads frames in and writes replies
// and events out; one that prepares each request (`ConnectionService.prepare` — for the
// engine, a push's files hashed and stored); and one that answers each prepared request, in
// the order the frames arrived — one that may block, a `wait` until the graph settles, on a
// thread of its own. A client with several pushes in flight has the next one prepared while
// the service records the one before (#163). Each request gets its reply back on the same
// stream, its parts first when it streams (B-137), and events go out on that stream too, so
// they cannot interleave with a reply.
//
// What a request means is the service's. This file knows frames, correlation IDs and the
// `Request` and `Response` types, so that every server — the engine's, and a cache's —
// answers its clients through the one implementation of the wire.

import Foundation
import Network
import SemelProtocol

/// One request's way back to its client for the parts of a streamed reply. A value per
/// request rather than one per connection, because a part has to carry the request's
/// correlation ID and a connection may have several requests in hand at once (a blocking
/// one runs on its own thread).
public protocol ReplyStream: AnyObject {

    /// Sends one part ahead of the reply's last. Throws when the part cannot be sent,
    /// which ends the request: the handler answers its error as the last frame. Only a
    /// case that `mayStream` is a part; sending another is a bug, caught in a debug build.
    func send(part: Response) throws
}

/// What a server does with one connection: one per client, made when it connects.
public protocol ConnectionService: AnyObject {

    /// Whether the client asked for events; read on whatever thread delivers one.
    var receivesEvents: Bool { get }

    /// The part of answering that can run ahead of the requests before it — reading the
    /// request's body, say. On the connection's preparing queue, in arrival order.
    func prepare(_ request: Request, body: Data?) -> PreparedAnswer

    /// The client has gone and every request it sent has been answered. On the answering
    /// queue, once.
    func connectionEnded()
}

/// A request made ready to answer: whether answering may block, and the answer itself,
/// which sends any parts through the stream it is given and returns the last frame.
public struct PreparedAnswer {

    /// True for a request whose answer waits on something outside the connection — the
    /// engine's `wait`. It runs on a thread of its own, not the answering queue, so the
    /// requests behind it are answered meanwhile.
    public let blocks: Bool

    let answer: (any ReplyStream) -> (Response, Data?)

    public init(blocks: Bool, answer: @escaping (any ReplyStream) -> (Response, Data?)) {
        self.blocks = blocks
        self.answer = answer
    }
}

public final class ServerConnection {

    public let service: any ConnectionService

    /// Called on the answering queue once, after the peer is gone, every request received
    /// before has been answered, and the service told.
    public var onClose: ((ServerConnection) -> Void)?

    private let stream: FrameStream
    private let preparing: DispatchQueue
    private let handling: DispatchQueue
    /// On `handling`.
    private var finished = false

    /// The queue named by `label` is the stream's: frames are read on it and replies and
    /// events leave through it, so nothing that waits runs there. A request is prepared on
    /// the queue after it and answered on the one after that.
    public init(connection: NWConnection, service: any ConnectionService, label: String) {
        self.service   = service
        self.preparing = DispatchQueue(label: label + ".preparing")
        self.handling  = DispatchQueue(label: label + ".handling")
        self.stream    = FrameStream(connection: connection, queue: DispatchQueue(label: label))
        stream.onFrame = { [weak self] frame in self?.receive(frame) }
        stream.onClose = { [weak self] _ in self?.afterRequestsReceived { $0.finish() } }
    }

    public func start() {
        stream.start()
    }

    public func close() {
        stream.close()
        afterRequestsReceived { $0.finish() }
    }

    /// Runs `work` on the answering queue once every request received so far has been
    /// answered — the order the two stages keep, so a service is told its client has gone
    /// behind the requests that arrived before it went, never in front of one of them.
    private func afterRequestsReceived(_ work: @escaping (ServerConnection) -> Void) {
        preparing.async { [self] in
            handling.async { [self] in work(self) }
        }
    }

    /// Writes an already-encoded event to this client. Called on any thread; FrameStream
    /// serializes the send on this connection's queue.
    ///
    /// An event too large to frame is dropped: nobody is waiting on it, and a client in
    /// the middle of a command can lose a notice where it cannot lose its connection.
    public func deliver(_ frame: Frame) {
        try? stream.send(frame)
    }

    // MARK: - Requests

    private func receive(_ frame: Frame) {
        guard frame.kind == .request, !frame.continues else {
            // A client sends requests only, each one frame; anything else is a framing bug
            // on its side.
            return
        }
        let request: Request
        do {
            request = try frame.request()
        } catch {
            if let reply = Self.reply(toUndecodable: frame) {
                try? stream.send(reply)
            }
            return
        }
        let body = frame.body.isEmpty ? nil : frame.body
        let correlationID = frame.correlationID

        preparing.async { [self] in
            let prepared = service.prepare(request, body: body)
            handling.async { [self] in
                answer(prepared, to: request, correlationID: correlationID)
            }
        }
    }

    /// On the answering queue, in the order the requests arrived.
    ///
    /// A request that blocks is not answered on this queue: requests the client sends
    /// behind it would wait with it. A thread of its own, then, and not the cooperative
    /// pool's, whose threads the engine's loop needs. It is started only here, so every
    /// request that arrived before it has been answered when it begins to wait — pushes in
    /// flight ahead of a wait are recorded before it can settle. A request that arrived
    /// after it may be answered first; the client matches replies to requests by
    /// correlation ID, so that reorders nothing it reads, and no command of the client's
    /// sends behind a wait before the wait is answered.
    private func answer(_ prepared: PreparedAnswer, to request: Request, correlationID: UInt64) {
        let parts = PartSender(stream: stream, correlationID: correlationID)
        guard prepared.blocks else {
            let (response, replyBody) = prepared.answer(parts)
            reply(response, body: replyBody, correlationID: correlationID, request: request)
            return
        }
        let thread = Thread { [self] in
            let (response, replyBody) = prepared.answer(parts)
            reply(response, body: replyBody, correlationID: correlationID, request: request)
        }
        thread.name = "semel.wait"
        thread.start()
    }

    /// The parts of one request's reply (B-137): frames with the continue flag, on the same
    /// stream as the last, so they leave ahead of it and in the order they were sent.
    private final class PartSender: ReplyStream {
        private let stream:        FrameStream
        private let correlationID: UInt64

        init(stream: FrameStream, correlationID: UInt64) {
            self.stream        = stream
            self.correlationID = correlationID
        }

        func send(part: Response) throws {
            assert(part.mayStream, "only list, remove and errors stream; \(part) is one frame")
            try stream.send(try Frame.response(part, correlationID: correlationID, continues: true))
        }
    }

    /// One reply frame back on the stream, from whichever thread answered the request;
    /// `FrameStream.send` serializes the write on the stream's queue.
    private func reply(_ response: Response, body: Data?, correlationID: UInt64, request: Request) {
        do {
            try stream.send(try Frame.response(response, correlationID: correlationID, body: body ?? Data()))
        } catch {
            // Only an over-limit reply fails to frame, and nothing has been written, so the
            // client hears what was refused and how large it was — an answer it can act on,
            // where a closed socket would leave it with a number.
            if let fallback = try? Frame.response(Self.tooLarge(request, error: error),
                                                  correlationID: correlationID) {
                try? stream.send(fallback)
            }
        }
    }

    /// The reply to a reply that does not fit. `Frame.maximumJSONLength` bounds what a
    /// declared length alone can make this process allocate, so the answer is to say so,
    /// naming the request and the size, and not to raise the limit.
    private static func tooLarge(_ request: Request, error: Error) -> Response {
        guard case FrameError.jsonTooLarge(let declared, let limit) = error else {
            return .error(.nodeError(description: "the reply could not be framed: \(error)"))
        }
        return .error(.replyTooLarge(request: name(of: request), bytes: Int(declared), limit: Int(limit)))
    }

    /// What to call a request in a message to the user: the verb, without its arguments.
    private static func name(of request: Request) -> String {
        switch request {
        case .hello:
            return "hello"
        case .daemon(let daemonRequest):
            return String(describing: daemonRequest).prefix(while: { $0 != "(" }).description
        }
    }

    /// The answer to a request whose JSON names nothing this build knows. The connection
    /// survives: the frame was well formed, only the message was not. Nil only if a small
    /// fixed error message somehow fails to encode, in which case there is nothing to say.
    public static func reply(toUndecodable frame: Frame) -> Frame? {
        try? Frame.response(.error(.malformedRequest(description: "the request could not be decoded")),
                            correlationID: frame.correlationID)
    }

    private func finish() {
        guard !finished else {
            return
        }
        finished = true
        service.connectionEnded()
        onClose?(self)
    }
}
