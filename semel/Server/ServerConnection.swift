// ServerConnection.swift
// SemelServer
//
// One client. A FrameStream, a Session, the shared handler, and three serial queues of its
// own: the stream's, which reads frames in and writes replies and events out; one that
// prepares each request (`RequestHandler.prepare`, a push's files hashed and stored); and
// one that hands each prepared request to the handler, in the order the frames arrived —
// a `wait`, which blocks until the graph settles, on a thread of its own. A client with
// several pushes in flight has the next one prepared while the handler records the one
// before. Each request gets one reply frame back on the same stream, and events from the
// registry go out on that stream too, so they cannot interleave with a reply.

import Foundation
import Network
import SemelProtocol
import SemelTransport

final class ServerConnection {

    let session = Session()

    /// Called on the handling queue once, after the peer is gone, every request received
    /// before has been handled, and the session ended.
    var onClose: ((ServerConnection) -> Void)?

    private let stream: FrameStream
    private let handler: RequestHandler
    private let preparing: DispatchQueue
    private let handling: DispatchQueue
    /// On `handling`.
    private var finished = false

    /// The queue named by `label` is the stream's: frames are read on it and replies and
    /// events leave through it, so nothing that waits runs there. A request is prepared on
    /// the queue after it and handled on the one after that.
    init(connection: NWConnection, handler: RequestHandler, label: String) {
        self.handler   = handler
        self.preparing = DispatchQueue(label: label + ".preparing")
        self.handling  = DispatchQueue(label: label + ".handling")
        self.stream    = FrameStream(connection: connection, queue: DispatchQueue(label: label))
        stream.onFrame = { [weak self] frame in self?.receive(frame) }
        stream.onClose = { [weak self] _ in self?.afterRequestsReceived { $0.finish() } }
    }

    func start() {
        stream.start()
    }

    func close() {
        stream.close()
        afterRequestsReceived { $0.finish() }
    }

    /// Runs `work` on the handling queue once every request received so far has been
    /// handled — the order the two stages keep, so a session is ended behind the requests
    /// that arrived before its peer went, never in front of a `beginBatch` among them.
    private func afterRequestsReceived(_ work: @escaping (ServerConnection) -> Void) {
        preparing.async { [self] in
            handling.async { [self] in work(self) }
        }
    }

    /// Writes an already-encoded event to this client. Called from the registry, on any
    /// thread; FrameStream serializes the send on this connection's queue.
    ///
    /// An event too large to frame is dropped: nobody is waiting on it, and a client in
    /// the middle of a command can lose a notice where it cannot lose its connection.
    func deliver(_ frame: Frame) {
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
            let prepared = handler.prepare(request, body: body)
            handling.async { [self] in
                handle(prepared, correlationID: correlationID)
            }
        }
    }

    /// On the handling queue, in the order the requests arrived.
    ///
    /// A wait blocks until the graph settles, and not on this queue: requests the client
    /// sends behind it would wait with it. A thread of its own, then, and not the
    /// cooperative pool's, whose threads the engine's loop needs (see the handler). It is
    /// started only here, so every request that arrived before it has been handled when it
    /// begins to wait — pushes in flight ahead of a wait are recorded before it can settle.
    /// A request that arrived after it may be answered first; the client matches replies to
    /// requests by correlation ID, so that reorders nothing it reads, and no command of the
    /// client's sends behind a wait before the wait is answered.
    private func handle(_ prepared: PreparedRequest, correlationID: UInt64) {
        let parts = PartSender(stream: stream, correlationID: correlationID)
        guard case .daemon(.wait) = prepared.request else {
            let (response, replyBody) = handler.handle(prepared, session: session, replyStream: parts)
            reply(response, body: replyBody, correlationID: correlationID, request: prepared.request)
            return
        }
        let thread = Thread { [self] in
            let (response, replyBody) = handler.handle(prepared, session: session, replyStream: parts)
            reply(response, body: replyBody, correlationID: correlationID, request: prepared.request)
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

    /// One reply frame back on the stream, from whichever thread handled the request;
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
    static func reply(toUndecodable frame: Frame) -> Frame? {
        try? Frame.response(.error(.malformedRequest(description: "the request could not be decoded")),
                            correlationID: frame.correlationID)
    }

    private func finish() {
        guard !finished else {
            return
        }
        finished = true
        handler.endSession(session)
        onClose?(self)
    }
}
