// Messages.swift
// SemelProtocol
//
// The three things that cross the wire, each an enum *of roles*. Which role a message
// belongs to is then a type-level fact: adding a role is a new file rather than an edit to
// every switch, and a server that does not offer a role rejects the whole group with one
// error case. Only `daemon` has messages; `cache` (B-30 role 1) and `runner` (role 2)
// arrive as new cases here and new files beside DaemonMessages.swift.
//
// The roots hand-write their Codable conformance. Their payloads are single values with no
// natural field name, and synthesis would key an unlabeled value as `_0`; labeling it
// would put a meaningless word (`{"daemon":{"request":…}}`) on every message. The
// hand-written form is `{"daemon":{"list":…}}` — the role wrapping the message, nothing
// else — and it is short enough to read in full here.
//
// Every type here is `Sendable`: the connections that will carry these are `async`, and a
// public type is not implicitly `Sendable` outside its module.

import Foundation

public enum Request: Equatable, Sendable {
    case hello(Hello)
    case daemon(DaemonRequest)
}

public enum Response: Equatable, Sendable {
    case hello(HelloResponse)
    case daemon(DaemonResponse)
    case error(ErrorResponse)
}

public enum Event: Equatable, Sendable {
    case daemon(DaemonEvent)
}

// MARK: - Codable

extension Request: Codable {

    private enum CodingKeys: String, CodingKey {
        case hello
        case daemon
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key       = try container.singleKey(in: decoder)

        switch key {
        case .hello:  self = .hello(try container.decode(Hello.self, forKey: .hello))
        case .daemon: self = .daemon(try container.decode(DaemonRequest.self, forKey: .daemon))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .hello(let hello):    try container.encode(hello,   forKey: .hello)
        case .daemon(let request): try container.encode(request, forKey: .daemon)
        }
    }
}

extension Response: Codable {

    private enum CodingKeys: String, CodingKey {
        case hello
        case daemon
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key       = try container.singleKey(in: decoder)

        switch key {
        case .hello:  self = .hello(try container.decode(HelloResponse.self, forKey: .hello))
        case .daemon: self = .daemon(try container.decode(DaemonResponse.self, forKey: .daemon))
        case .error:  self = .error(try container.decode(ErrorResponse.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .hello(let hello):     try container.encode(hello,    forKey: .hello)
        case .daemon(let response): try container.encode(response, forKey: .daemon)
        case .error(let error):     try container.encode(error,    forKey: .error)
        }
    }
}

extension Event: Codable {

    private enum CodingKeys: String, CodingKey {
        case daemon
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key       = try container.singleKey(in: decoder)

        switch key {
        case .daemon: self = .daemon(try container.decode(DaemonEvent.self, forKey: .daemon))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .daemon(let event): try container.encode(event, forKey: .daemon)
        }
    }
}

extension KeyedDecodingContainer {

    /// A root message is exactly one role key. `allKeys` on a strict, typed container only
    /// lists keys that convert to `Key`, so `{"cache":{}}` would report `found []` and
    /// `{"daemon":{…},"cache":{}}` would decode silently as `.daemon` — an unrecognized key
    /// beside a recognized one would go unseen. To find every key actually present, this
    /// re-opens the same decoder with a permissive, string-only key type and requires both
    /// that container and the typed one to see exactly one key, so the error names every
    /// key that was there and a peer mismatch is diagnosable from the log line.
    func singleKey(in decoder: Decoder) throws -> Key {
        let permissiveContainer = try decoder.container(keyedBy: AnyCodingKey.self)
        let presentKeys         = permissiveContainer.allKeys.map(\.stringValue)

        guard presentKeys.count == 1, allKeys.count == 1, let key = allKeys.first else {
            let context = DecodingError.Context(codingPath: codingPath,
                                                debugDescription: "expected exactly one role key, found \(presentKeys.sorted())")
            throw DecodingError.dataCorrupted(context)
        }
        return key
    }
}

/// A `CodingKey` that accepts any string, used only to list every key a JSON object
/// actually has — the typed `CodingKeys` enums used elsewhere in this file reject unknown
/// keys instead of listing them, which is exactly the gap `singleKey(in:)` closes.
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue:    Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

/// Protocol-level failures. Build errors are not among them: a node that fails to compile
/// is data, returned by `errors`, mirroring the engine's distinction between a node failure
/// and an `UnrecoverableError`.
public enum ErrorResponse: Codable, Equatable, Sendable {
    case pathNotFound(path: String)
    case notAFolder(path: String)
    case nodeError(description: String)
    case roleNotOffered(role: Role)
    case malformedRequest(description: String)
    /// The answer to this request does not fit a frame. Sent in place of that answer, so
    /// that a reply too large is something the client can report rather than a socket that
    /// closes under it.
    case replyTooLarge(request: String, bytes: Int, limit: Int)
    /// The machine, not the request, is broken. The server answers the in-flight request
    /// with this, then exits; every client sees its connection close.
    case unrecoverable(message: String)
}
