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
    /// **The rule: any change to the message set changes this number.** Not only a change to
    /// the framing — adding, removing or reshaping a case of `DaemonRequest`,
    /// `DaemonResponse`, `DaemonEvent` or `ErrorResponse` is what a peer built against the
    /// other side decodes wrongly, and this number is the one thing that lets the handshake
    /// say so instead. Nothing enforces it: the test that pins the number only fires when
    /// someone changes the number.
    ///
    /// Version 13 gives `tools` a platform to answer for, since a machine setting is one
    /// per platform. Version 12 gives an error entry a `missingSource`: the path a report
    /// says nobody has pushed, typed, so a client can push it. Version 11 adds the
    /// `artifacts` event, one settle's diff over the products:
    /// appeared, changed, disappeared. Version 10 gives `debug` a cache key to ask about,
    /// answering that entry's key material where the bare request answers the graph.
    /// Version 9 adds the `missingOutputPort` kind to `check`'s findings, for a node
    /// holding no row for a port its type declares. Version 8 gives `ls` a status per
    /// state the graph can be in about a name — `notProduced`, `deleted` and `failed`
    /// where version 7 had `missing` and `error`.
    /// Version 7 adds `check`, whose findings travel in the reply's body. Version 6 adds
    /// the `settled` event, which carries one settle's totals. Version 5's
    /// `reset` carries a flag for whether the cache goes too, and answers with the path its
    /// copy of the graph was written to; every earlier version's took no argument and
    /// answered `ok`. Version 4's `ErrorRecord` carries the size of the cascade under a
    /// failure, where version 3's carried a record per node in it. Version 3's `remove`
    /// reply carries files and folders apart, where version 2's carried one list. Version 2
    /// carries `debug`'s text in the frame body; version 1 carried it in the reply's JSON. A
    /// peer speaking an older one decodes such a reply as an empty answer and prints
    /// nothing, which is why the mismatch is worth a rejection naming both.
    /// Version 17 adds the `explain` request and its reply, why the last settle did what
    /// it did to one node (B-91).
    /// Version 16 adds the `progress` event, where a settle stands (B-95).
    /// Version 15 renames the check finding `unreadableGraphSpec` to `staleIdentity` (B-115).
    /// Version 14 adds the `collect` request and its `collected` reply (B-14).
    /// Version 18 gives an error entry the `writers` of a machine file nobody has written
    /// (B-109).
    /// Version 19 adds `pushSymbolicLink`, and `symbolicLink` in answer to a `fetch` of one
    /// (B-77).
    public static let current = 19
}

public struct Hello: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let role:            Role

    public init(protocolVersion: Int, role: Role) {
        self.protocolVersion = protocolVersion
        self.role            = role
    }

    /// A hello that speaks whatever version this module holds.
    ///
    /// This is an overload rather than `protocolVersion: Int = ProtocolVersion.current`,
    /// because a default argument is not a call: the compiler emits a default-argument
    /// generator with the number folded into it as a coalesced copy in *every* caller's
    /// object file. A caller whose object outlives a change to `ProtocolVersion.current`
    /// therefore carries the old number, the linker picks whichever copy it meets first, and
    /// two halves of one binary disagree about the version they speak. An ordinary
    /// initializer body stays in this module, so every caller reads the constant at the
    /// moment it asks for it (B-84).
    public init(role: Role) {
        self.init(protocolVersion: ProtocolVersion.current, role: role)
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
