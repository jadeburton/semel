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
/// one. Only `daemon` has messages today; the others are named so that `Hello` does not
/// change when they arrive.
public enum Role: String, Codable, Equatable {
    case daemon
    case cache
    case runner
}

public enum ProtocolVersion {
    public static let current = 1
}

public struct Hello: Codable, Equatable {
    public let protocolVersion: Int
    public let role:            Role

    public init(protocolVersion: Int = ProtocolVersion.current, role: Role) {
        self.protocolVersion = protocolVersion
        self.role            = role
    }
}

public enum HelloRejection: Codable, Equatable {
    case versionMismatch(client: Int, server: Int)
    case roleNotOffered(role: Role)
}

public enum HelloResponse: Codable, Equatable {
    /// `databasePath` is here because the REPL prints "Graph: …" at startup from local
    /// state today, and after the split the client has no such state.
    case accepted(serverVersion: String, databasePath: String)
    case rejected(reason: HelloRejection)
}
