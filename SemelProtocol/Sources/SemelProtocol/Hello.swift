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

/// What a peer is, when two processes meet: the engine's server (`daemon`), a shared cache
/// (`cache`, the `semel-cache` program), a remote runner when it comes. A server offers
/// some subset and a client asks for one; the role names what the peer is, not which binary
/// runs it.
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
    /// Version 20 adds `contentRoots` and `folderChildren` and their replies, what a push
    /// compares with the disk before it sends (B-132).
    /// Version 21 gives a `HeldFolderRoot` the dot-named files its folder holds, which a
    /// client folds into its root of the disk (B-77).
    /// Version 22 adds `pushFiles` and its reply, several files to a request.
    /// Version 23 lets `list`, `remove` and `errors` arrive in parts, one frame each, with
    /// framing version 2's continue flag on all but the last (B-137).
    /// Version 24 gives an error record the products it stops, lets `errors` ask for one
    /// product's, and adds `notAProduct` for a path that names none (B-142).
    /// Version 25 adds `batchRejected`, the lock barrier's refusal of a batch at `commit`,
    /// and `checkpoint`, `checkpoints` and `restore` with their replies (B-146).
    /// Version 26 carries an error record as the document its node published, the products
    /// without a value and the node's facts, where earlier versions carried rendered
    /// messages, and `batchRejected` carries its lock's problem as a typed value (the
    /// 2026-10-09 error report design, B-145).
    /// Version 27 adds `cache` and `cacheLimit` with their replies, the cache's sizes and
    /// the home's limit (B-148).
    /// Version 28 adds the cache role (B-153): `CacheRequest` and `CacheResponse`, a hello's
    /// `wantsWrite` and the cache's answer to it, and `cacheStoreFailed`.
    /// Version 29 gives the `artifacts` event the folder of the tree product each path is
    /// an entry of (B-150).
    /// Version 30 gives a hello the `identity` a client names itself by to a cache, a cache's
    /// `entry` the objects it holds with their sizes, and the engine's requests and replies
    /// for its shared cache: `cacheServer`, `cacheIdentity`, `sharedCache`, and `cache`'s
    /// summary of the shared cache (B-153).
    /// Version 31 bounds `batchRejected`: it names at most fifty of the batch's paths and
    /// counts the rest in `pathsNotListed`, so the rejection always fits a frame (B-161).
    /// Version 32 gives `batchRejected` its `listing`: the names the locked folder lacks
    /// against its lock's tree and those it holds that the tree does not, each bounded as
    /// the paths are (B-164).
    /// Version 33 gives a running node in a `progress` record its `subject`, what it is
    /// computed for as the error report names it, and its `identity` (B-168).
    /// Version 34 gives the `errors` reply and event the graph's `ProductTally`, which the
    /// summary line counts, and adds `machineFileRemoved` to the conditions a record's
    /// document can carry (B-169).
    public static let current = 34
}

public struct Hello: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let role:            Role
    /// Whether the client means to write: what a cache asks of its writers (B-153). A cache
    /// is read-only to a client by default, and the server decides from its configuration
    /// whether a client that asks may; the engine's server reads nothing from it.
    public let wantsWrite:      Bool
    /// The name the client gives itself to a cache, `cache.identity` in an engine's home:
    /// asserted, not authenticated, over a LAN or a VPN (the August design). Nil when the
    /// home names none. Carried so that a server granting writes to named clients, and
    /// authentication after it, is a change to the server and not to the protocol; the
    /// engine's server reads nothing from it.
    public let identity:        String?

    public init(protocolVersion: Int, role: Role, wantsWrite: Bool, identity: String?) {
        self.protocolVersion = protocolVersion
        self.role            = role
        self.wantsWrite      = wantsWrite
        self.identity        = identity
    }

    public init(protocolVersion: Int, role: Role, wantsWrite: Bool) {
        self.init(protocolVersion: protocolVersion, role: role, wantsWrite: wantsWrite, identity: nil)
    }

    public init(protocolVersion: Int, role: Role) {
        self.init(protocolVersion: protocolVersion, role: role, wantsWrite: false, identity: nil)
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
        self.init(protocolVersion: ProtocolVersion.current, role: role, wantsWrite: false, identity: nil)
    }

    /// A hello that speaks this module's version and says whether it means to write. An
    /// overload for the same reason as `init(role:)`.
    public init(role: Role, wantsWrite: Bool) {
        self.init(protocolVersion: ProtocolVersion.current, role: role, wantsWrite: wantsWrite, identity: nil)
    }

    /// A hello that speaks this module's version, says whether it means to write and names
    /// the client. An overload for the same reason as `init(role:)`.
    public init(role: Role, wantsWrite: Bool, identity: String?) {
        self.init(protocolVersion: ProtocolVersion.current, role: role, wantsWrite: wantsWrite, identity: identity)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case role
        case wantsWrite
        case identity
    }

    /// `wantsWrite` absent reads as false, and `identity` absent as none. A hello is the one message that has to decode
    /// across versions: a peer speaking an older message set must still be told so, with
    /// both numbers, and a hello that failed to decode for want of a field would be refused
    /// as malformed instead.
    public init(from decoder: any Decoder) throws {
        let container   = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        role            = try container.decode(Role.self, forKey: .role)
        wantsWrite      = try container.decodeIfPresent(Bool.self, forKey: .wantsWrite) ?? false
        identity        = try container.decodeIfPresent(String.self, forKey: .identity)
    }
}

/// What a cache grants a client it accepts.
public enum CacheAccess: String, Codable, Equatable, Sendable {
    /// Reads and writes: a client that asked to write, of a server whose writers include it.
    case readWrite
    /// Reads only: a client that did not ask to write, or one the server will not let.
    case readOnly
}

public enum HelloRejection: Codable, Equatable, Sendable {
    case versionMismatch(client: Int, server: Int)
    case roleNotOffered(role: Role)
}

public enum HelloResponse: Codable, Equatable, Sendable {
    /// The engine's server took the client on. `databasePath` is here because the REPL
    /// prints "Graph: …" at startup and the client has no local state to take it from.
    case accepted(serverVersion: String, databasePath: String)
    /// A cache took the client on, with what it may do: read and write, or read only.
    case cacheAccepted(access: CacheAccess)
    case rejected(reason: HelloRejection)
}
