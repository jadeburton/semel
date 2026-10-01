// Frame+Messages.swift
// SemelProtocol
//
// Typed messages in and out of frames. A connection — in-process or socket — calls these
// and nothing else; it never touches `MessageCoder` or `Frame.json` directly.

import Foundation

public enum MessageError: Error, Equatable, CustomStringConvertible, Sendable {
    case wrongKind(expected: FrameKind, actual: FrameKind)

    public var description: String {
        switch self {
        case .wrongKind(let expected, let actual):
            return "expected a \(expected) frame but received a \(actual) frame"
        }
    }
}

extension Frame {

    // MARK: - Building

    public static func request(_ request: Request, correlationID: UInt64, body: Data = Data()) throws -> Frame {
        Frame(kind: .request, correlationID: correlationID, json: try MessageCoder.encode(request), body: body)
    }

    /// `continues` marks a part of a streamed reply: a frame that more frames for this
    /// correlation ID follow.
    public static func response(_ response: Response, correlationID: UInt64, body: Data = Data(),
                                continues: Bool = false) throws -> Frame {
        Frame(kind: .response, correlationID: correlationID, json: try MessageCoder.encode(response), body: body,
              continues: continues)
    }

    /// Events answer nothing, so they carry correlation ID zero.
    public static func event(_ event: Event) throws -> Frame {
        Frame(kind: .event, correlationID: 0, json: try MessageCoder.encode(event))
    }

    // MARK: - Reading

    public func request() throws -> Request {
        try requireKind(.request)
        return try MessageCoder.decode(Request.self, from: json)
    }

    public func response() throws -> Response {
        try requireKind(.response)
        return try MessageCoder.decode(Response.self, from: json)
    }

    public func event() throws -> Event {
        try requireKind(.event)
        return try MessageCoder.decode(Event.self, from: json)
    }

    private func requireKind(_ expected: FrameKind) throws {
        guard kind == expected else {
            throw MessageError.wrongKind(expected: expected, actual: kind)
        }
    }
}
