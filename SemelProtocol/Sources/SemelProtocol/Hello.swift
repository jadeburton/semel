// Hello.swift
// SemelProtocol
//
// The first exchange on every connection. The client names the role it wants and the
// message-set version it speaks; the server accepts or says why not.
//
// This is a second version field on purpose. `Frame.version` governs framing and a
// mismatch there closes the connection, because nothing further can be trusted.
// `protocolVersion` governs the message set and is negotiated once framing is known to
// work, so a mismatch can be reported as a clean rejection with both numbers in it.

import Foundation

/// One `semelserv` binary, several modes. A server offers some subset; a client asks for
/// one. Only `daemon` has messages; the others are named so that `Hello` does not change
/// when they arrive.
public enum Role: String, Codable, Equatable, Sendable {
    case daemon
    case cache
    case runner
}

public enum ProtocolVersion {
    /// Version 2 moves `debug`'s text from the reply's JSON to the frame body. A peer that
    /// speaks version 1 would decode the reply as an empty answer and print nothing, so
    /// the mismatch is worth a rejection that names both numbers.
    public static let current = 2
}

public struct Hello: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let role:            Role

    public init(protocolVersion: Int = ProtocolVersion.current, role: Role) {
        self.protocolVersion = protocolVersion
        self.role            = role
    }
}

public enum HelloRejection: Codable, Equatable, Sendable {
    case versionMismatch(client: Int, server: Int)
    case roleNotOffered(role: Role)
}

public enum HelloResponse: Codable, Equatable, Sendable {
    /// `databasePath` is here because the REPL prints "Graph: …" at startup and the client
    /// has no local state to take it from.
    case accepted(serverVersion: String, databasePath: String)
    case rejected(reason: HelloRejection)
}
