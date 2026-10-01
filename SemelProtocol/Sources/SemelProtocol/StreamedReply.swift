// StreamedReply.swift
// SemelProtocol
//
// A reply that arrives in parts (B-137), read on the client's side: frame by frame, as a
// connection receives them, and part by part, as a caller that wants the whole reply joins
// them. Both connections use these, so a socket and the in-process pretend wire read a
// stream by one rule — and the rule can be tested here, with no connection at all.

import Foundation

/// How a streamed reply can go wrong on the client's side. Only one of them is anything
/// but a server bug.
public enum ReplyStreamError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The connection closed after a reply had begun and before its last frame: what came
    /// is not the reply, and nothing says how much is missing. Names the request, because
    /// a client may have several in flight when its connection goes.
    case truncated(correlationID: UInt64, partsReceived: Int)
    /// A frame marked as continuing carried a response that may not stream, which a waiter
    /// handed it as a part would take for the whole.
    case notStreamable
    /// A part, or the last frame, was a different case from the parts before it.
    case mismatchedPart

    public var description: String {
        switch self {
        case .truncated(let correlationID, let partsReceived):
            return "the connection closed in the middle of the reply to request \(correlationID), "
                 + "after \(partsReceived) part\(partsReceived == 1 ? "" : "s"); what arrived is not the whole answer"
        case .notStreamable:
            return "the server sent a reply in parts that never streams"
        case .mismatchedPart:
            return "the server sent a reply in parts that do not join into one answer"
        }
    }
}

/// So that a client printing `localizedDescription` prints the sentence.
extension ReplyStreamError: LocalizedError {
    public var errorDescription: String? { description }
}

extension Response {

    /// Whether this may be a part of a streamed reply: one of the daemon cases that stream,
    /// and never a hello or an error.
    public var mayStream: Bool {
        guard case .daemon(let daemonResponse) = self else {
            return false
        }
        return daemonResponse.mayStream
    }
}

/// One request's reply as its frames arrive: a part for each frame marked as continuing,
/// then the last. Remembers how many parts it has seen, which is what decides whether a
/// connection that closes now has cut a reply short or simply never answered.
public struct IncomingReply: Sendable {

    public enum Arrival: Equatable, Sendable {
        /// A part ahead of the last. Parts carry no body.
        case part(Response)
        /// The frame without the continue flag, which ends the reply.
        case last(Response, body: Data?)
    }

    public let correlationID: UInt64
    public private(set) var partsReceived = 0

    public init(correlationID: UInt64) {
        self.correlationID = correlationID
    }

    /// Reads one response frame of this reply. Throws for a frame that is not a response,
    /// one whose JSON does not decode, and a part whose case may not stream.
    public mutating func receive(_ frame: Frame) throws -> Arrival {
        let response = try frame.response()
        guard frame.continues else {
            return .last(response, body: frame.body.isEmpty ? nil : frame.body)
        }
        guard response.mayStream else {
            throw ReplyStreamError.notStreamable
        }
        partsReceived += 1
        return .part(response)
    }

    /// What the reply comes to when the connection closes before its last frame: truncated
    /// once a part has come, and nil when nothing has, which the connection reports as its
    /// own closing.
    public var truncation: ReplyStreamError? {
        partsReceived > 0 ? .truncated(correlationID: correlationID, partsReceived: partsReceived) : nil
    }
}

/// The parts of one reply, joined into the reply a caller that wants the whole would have
/// had from one frame. Costs the caller the whole reply's memory; a caller that can act on
/// each part as it comes takes them one at a time instead (`SemelConnection.send(_:body:onPart:)`).
public struct ReplyParts: Sendable {

    private var joined: DaemonResponse?

    public init() {}

    /// Adds the next part, after the ones before it.
    public mutating func append(_ part: Response) throws {
        guard case .daemon(let daemonPart) = part, daemonPart.mayStream else {
            throw ReplyStreamError.notStreamable
        }
        guard let earlier = joined else {
            joined = daemonPart
            return
        }
        guard let longer = earlier.appending(daemonPart) else {
            throw ReplyStreamError.mismatchedPart
        }
        joined = longer
    }

    /// The whole reply: the parts with the last frame's response after them. An error that
    /// ends a stream is the reply — the request failed, whatever its parts said — and with
    /// no parts the last response is the reply as it came.
    public func whole(endingWith last: Response) throws -> Response {
        guard let joined else {
            return last
        }
        switch last {
        case .error:
            return last
        case .daemon(let lastPart):
            guard let whole = joined.appending(lastPart) else {
                throw ReplyStreamError.mismatchedPart
            }
            return .daemon(whole)
        case .hello:
            throw ReplyStreamError.mismatchedPart
        }
    }
}
