// InProcessConnection.swift
// SemelServer
//
// A connection with no socket. It encodes every request to a frame and decodes it again
// before the handler sees it, and puts every reply through the same pair, so that the
// codec and the message set are exercised by every command a client sends long before a
// real transport exists. Handing the typed values straight across would make this a
// function call with extra steps and prove nothing.
//
// It is also the handler's event sink: an event becomes a frame, is decoded, and reaches
// `onEvent` — the same path a socket client will see.

import Foundation
import SemelProtocol

public final class InProcessConnection: SemelConnection, EventSink {

    public let session = Session()

    public var onEvent: ((Event) -> Void)? {
        get { lock.withLock { eventHandler } }
        set { lock.withLock { eventHandler = newValue } }
    }

    private let handler: RequestHandler
    private let lock = NSLock()
    private var eventHandler: ((Event) -> Void)?
    private var nextCorrelationID: UInt64 = 1

    public init(handler: RequestHandler) {
        self.handler = handler
        handler.eventSink = self
    }

    // MARK: - SemelConnection

    public func send(_ request: Request, body: Data?) throws -> (Response, Data?) {
        let correlationID = lock.withLock { () -> UInt64 in
            defer { nextCorrelationID += 1 }
            return nextCorrelationID
        }

        let requestFrame  = try roundTrip(try Frame.request(request, correlationID: correlationID, body: body ?? Data()))
        let (response, replyBody) = handler.handle(try requestFrame.request(), body: requestFrame.body, session: session)
        let responseFrame = try roundTrip(try Frame.response(response, correlationID: correlationID, body: replyBody ?? Data()))

        return (try responseFrame.response(), responseFrame.body.isEmpty ? nil : responseFrame.body)
    }

    // MARK: - EventSink

    public func deliver(_ event: Event) {
        guard session.isSubscribed, let eventHandler = onEvent else {
            return
        }
        // An event that cannot be framed is a bug in this package, not something a client
        // can act on; dropping it here is what a socket would do too.
        guard let frame = try? roundTrip(try Frame.event(event)), let decoded = try? frame.event() else {
            return
        }
        eventHandler(decoded)
    }

    // MARK: - The pretend wire

    /// Bytes out, bytes in: exactly what a socket would carry.
    private func roundTrip(_ frame: Frame) throws -> Frame {
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(frame))
        guard let decoded = try decoder.next() else {
            throw FrameError.unsupportedVersion(Frame.version)
        }
        return decoded
    }
}
