// RemoteCache.swift
// SemelCache
//
// A shared cache as an engine reaches it (B-153): one connection's worth of the requests
// the cache role has — ask for an entry, ask which objects the server lacks, fetch one, put
// one, put an entry — each a blocking call that answers or throws.
//
// A protocol rather than the client itself, and declared here rather than beside the
// socket, because of where the wire is: the protocol's messages name an entry by
// `CacheKey`, so `SemelProtocol` links this package, and the transport links the protocol.
// A client in this package that spoke frames would close that circle. So the cache says
// what it needs of a remote, `SharedCache` does everything an engine does with one — the
// fetch path, the population queue, the reconnection and the figures — and the one
// conformance that speaks frames over TCP lives above the transport (`SemelCacheClient`),
// where the engine's server installs it. A test hands `SharedCache` a remote over an
// in-process store, and the engine never learns which it has.

import Foundation
import SemelNodeKit

/// What a cache grants a client it accepts.
public enum RemoteCacheAccess: String, Codable, Equatable, Sendable {
    case readWrite
    case readOnly
}

/// An entry as a remote answers it: the bytes the engine encoded, what the build cost, and
/// every object the entry holds with its size — what a fetch of it would have to move.
public struct RemoteEntry: Equatable, Sendable {
    public let content: Data
    /// Milliseconds (`CacheCost`).
    public let cost: Int
    public let objects: [CachedObject]

    public init(content: Data, cost: Int, objects: [CachedObject]) {
        self.content = content
        self.cost    = cost
        self.objects = objects
    }
}

/// Why a remote did not answer. Each case is a state the caller branches on — whether the
/// connection is still worth using — and none is a sentence read back; what a case carries
/// as text is for a person to read in `cache`.
public enum RemoteCacheError: Error, Equatable, CustomStringConvertible {
    /// Nothing answered at the address, or the connection could not be made.
    case unreachable(address: String, reason: String)
    /// The server answered the hello with a refusal: a message set it does not speak, or a
    /// role it does not offer.
    case rejected(reason: String)
    /// The connection closed, or a request was not answered in time and the client closed
    /// it.
    case connectionLost(reason: String)
    /// The server refused the request and kept the connection: a write on a read-only
    /// connection, a body that did not hash to its name, an entry whose objects it lacks.
    case refused(reason: String)
    /// The server could not read or write its store.
    case storeFailed(reason: String)
    /// A reply that is not one the request can have, which leaves nothing on the
    /// connection to trust.
    case unexpectedReply(reason: String)

    /// Whether the connection is gone, or as good as: the client stops using it and the
    /// population queue's thread opens another.
    public var endsConnection: Bool {
        switch self {
        case .unreachable, .rejected, .connectionLost, .unexpectedReply:
            return true
        case .refused, .storeFailed:
            return false
        }
    }

    public var description: String {
        switch self {
        case .unreachable(let address, let reason):
            return "nothing answered at \(address) (\(reason))"
        case .rejected(let reason):
            return "the server refused this engine: \(reason)"
        case .connectionLost(let reason):
            return "the connection was lost: \(reason)"
        case .refused(let reason):
            return "the server refused a request: \(reason)"
        case .storeFailed(let reason):
            return "the server's store failed: \(reason)"
        case .unexpectedReply(let reason):
            return "the server answered something unexpected: \(reason)"
        }
    }
}

/// One shared cache, as an engine reaches it. Every call blocks until the server answers
/// and throws `RemoteCacheError` when it does not; none of them may block without bound,
/// since a lookup is made on a node's processing path — a conformance gives up on a request
/// that is not answered in time and says so as `connectionLost`.
///
/// Safe to call from several threads at once: the engine looks up from every thread that
/// processes a node while the population queue writes from its own.
public protocol RemoteCache: AnyObject {

    /// Where the remote is, as `cache` names it.
    var address: String { get }

    /// Opens a connection and says hello, asking to write, under `identity` when the home
    /// names one. What the server granted, or `unreachable` or `rejected`.
    func connect(identity: String?) throws -> RemoteCacheAccess

    /// Closes the connection, if one is open. A call in flight on it fails.
    func disconnect()

    /// The entry under `key`, or nil when the server has none.
    func entry(forKey key: CacheKey) throws -> RemoteEntry?

    /// Which of `hashes` the server does not hold.
    func missingObjects(among hashes: [DataObjectHash]) throws -> [DataObjectHash]

    /// The bytes filed under `hash`, as the server sent them — unverified — or nil when it
    /// has none. `expectedBytes` is the size the entry recorded, which a conformance may
    /// give the request the time to move.
    func object(hash: DataObjectHash, expectedBytes: Int) throws -> Data?

    /// Files `bytes` under `hash`; the server hashes them again.
    func putObject(hash: DataObjectHash, bytes: Data) throws

    /// Files an entry under `key`. Every object it names must be on the server already.
    func putEntry(key: CacheKey, cost: Int, objects: [DataObjectHash], content: Data) throws
}
