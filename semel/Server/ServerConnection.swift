// ServerConnection.swift
// SemelServ
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
    /// thread; FrameStream serialises the send on this connection's queue.
    func deliver(_ frame: Frame) {
        stream.send(frame)
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
                stream.send(reply)
            }
            return
        }
        let (response, body) = handler.handle(request, body: frame.body.isEmpty ? nil : frame.body, session: session)
        do {
            stream.send(try Frame.response(response, correlationID: frame.correlationID, body: body ?? Data()))
        } catch {
            // Only an over-limit reply fails to frame; the client learns of it as an error
            // rather than a silence.
            let failure = Response.error(.nodeError(description: "the reply could not be framed: \(error)"))
            if let fallback = try? Frame.response(failure, correlationID: frame.correlationID) {
                stream.send(fallback)
            }
        }
    }

    /// The answer to a request whose JSON names nothing this build knows. The connection
    /// survives: the frame was well formed, only the message was not. Nil only if a small
    /// fixed error message somehow fails to encode, in which case there is nothing to say.
    static func reply(toUndecodable frame: Frame) -> Frame? {
        try? Frame.response(.error(.malformedRequest(description: "the request could not be decoded")),
                            correlationID: frame.correlationID)
    }

    private var finished = false

    private func finish() {
        guard !finished else {
            return
        }
        finished = true
        handler.endSession(session)
        onClose?(self)
    }
}
