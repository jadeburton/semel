// ServerConnection.swift
// SemelServer
//
// One client. A serial queue of its own, a FrameStream, a Session, and the shared handler.
// Each request frame becomes one handler call on this queue and one reply frame back on
// the same stream, so replies leave in request order; events from the registry go out on
// the same stream and so cannot interleave with a reply.

import Foundation
import Network
import SemelProtocol
import SemelTransport

final class ServerConnection {

    let session = Session()

    /// Called on the connection's queue once, after the peer is gone and the session ended.
    var onClose: ((ServerConnection) -> Void)?

    private let stream: FrameStream
    private let handler: RequestHandler
    private let queue: DispatchQueue
    private var finished = false

    /// The queue named by `label` is a plain dispatch queue and must stay one: the handler
    /// parks it on `wait` until the engine settles, which a cooperative-pool thread could
    /// not afford to do.
    init(connection: NWConnection, handler: RequestHandler, label: String) {
        self.handler = handler
        self.queue   = DispatchQueue(label: label)
        self.stream  = FrameStream(connection: connection, queue: queue)
        stream.onFrame = { [weak self] frame in self?.receive(frame) }
        stream.onClose = { [weak self] _ in self?.finish() }
    }

    func start() {
        stream.start()
    }

    func close() {
        stream.close()
        queue.async { [self] in finish() }
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
        guard frame.kind == .request else {
            // A client sends requests only; anything else is a framing bug on its side.
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
        let (response, body) = handler.handle(request, body: frame.body.isEmpty ? nil : frame.body, session: session)
        do {
            try stream.send(try Frame.response(response, correlationID: frame.correlationID, body: body ?? Data()))
        } catch {
            // Only an over-limit reply fails to frame, and nothing has been written, so the
            // client hears what was refused and how large it was — an answer it can act on,
            // where a closed socket would leave it with a number.
            if let fallback = try? Frame.response(Self.tooLarge(request, error: error),
                                                  correlationID: frame.correlationID) {
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
