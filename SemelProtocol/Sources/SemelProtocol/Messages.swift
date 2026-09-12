// Messages.swift
// SemelProtocol
//
// The three things that cross the wire, each an enum *of roles*. Which role a message
// belongs to is then a type-level fact: adding a role is a new file rather than an edit to
// every switch, and a server that does not offer a role rejects the whole group with one
// error case. Only `daemon` exists today; `cache` (B-30 role 1) and `runner` (role 2)
// arrive as new cases here and new files beside DaemonMessages.swift.

//
// The roots hand-write their Codable conformance. Their payloads are single values with no
// natural field name, and synthesis would key an unlabelled value as `_0`; labelling it
// would put a meaningless word (`{"daemon":{"request":…}}`) on every message. The
// hand-written form is `{"daemon":{"list":…}}` — the role wrapping the message, nothing
// else — and it is short enough to read in full here.

import Foundation

public enum Request: Equatable {
    case hello(Hello)
    case daemon(DaemonRequest)
}

public enum Response: Equatable {
    case hello(HelloResponse)
    case daemon(DaemonResponse)
    case error(ErrorResponse)
}

public enum Event: Equatable {
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
        let key       = try container.singleKey()

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
        let key       = try container.singleKey()

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
        let key       = try container.singleKey()

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

    /// A root message is exactly one role key. Zero keys or two is not a message this build
    /// understands, and the error says which keys were there so a peer mismatch is
    /// diagnosable from the log line.
    func singleKey() throws -> Key {
        guard allKeys.count == 1, let key = allKeys.first else {
            let context = DecodingError.Context(codingPath: codingPath,
                                                debugDescription: "expected exactly one role key, found \(allKeys.map(\.stringValue))")
            throw DecodingError.dataCorrupted(context)
        }
        return key
    }
}

/// Protocol-level failures. Build errors are not among them: a node that fails to compile
/// is data, returned by `errors`, mirroring the engine's distinction between a node failure
/// and an `UnrecoverableError`.
public enum ErrorResponse: Codable, Equatable {
    case pathNotFound(path: String)
    case notAFolder(path: String)
    case nodeError(description: String)
    case roleNotOffered(role: Role)
    case malformedRequest(description: String)
    /// The machine, not the request, is broken. The server answers the in-flight request
    /// with this, then exits; every client sees its connection close.
    case unrecoverable(message: String)
}
