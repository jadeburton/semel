// CacheRoleMessages.swift
// SemelProtocol
//
// The cache role (B-153): an engine and a shared cache, `semel-cache`. Two tiers, as the
// August design has them — entries under their keys, and objects under their hashes — and
// a request for each thing a client does with them: ask for an entry, put one, ask which
// objects the server lacks, fetch one, put one. Bytes travel in the frame's body, never in
// its JSON, so an object or an entry is one frame whatever its size up to the body's limit.
//
// The server never reads inside an entry. The entry is the engine's encoding, carried and
// stored as it is; what the server needs to file it — the key, what the build cost, the
// objects it references — arrives as typed fields beside it. That keeps the entry's format
// the engine's business alone and makes the server a byte store with an index, which is
// also what lets it answer from memory.
//
// Every associated value is labeled, as on the daemon's messages, so no `_0` reaches the
// wire.

import Foundation
import SemelCache
import SemelNodeKit

public enum CacheRequest: Codable, Equatable, Sendable {
    /// The entry under `key`: answered `entry` with its bytes in the body, or `miss` — also
    /// when an object it references is no longer here, since a hit the client cannot
    /// complete is no hit.
    case getEntry(key: CacheKey)
    /// Files the entry in the body under `key`. `cost` is what the build took, in
    /// milliseconds (`CacheCost`), which eviction weighs; `objects` are every object the
    /// entry references, reached through the documents among them too, which must all be
    /// here already — the client puts them first. `length` is the body's length as the
    /// client meant it, the one check made on bytes the server does not read. Answered
    /// `stored` once the entry is in the server's index and its write-ahead log.
    case putEntry(key: CacheKey, cost: Int, objects: [DataObjectHash], length: Int)
    /// Which of `hashes` the server does not hold, in the order asked: what a client must
    /// fetch after a hit, or put before an entry.
    case hasObjects(hashes: [DataObjectHash])
    /// The object's bytes in the reply's body, or `miss`.
    case getObject(hash: DataObjectHash)
    /// Stores the body under `hash`, after hashing it: a body that hashes to something else
    /// is refused by name (`hashMismatch`), so a corruption on the way is loud rather than
    /// a wrong object served to every reader after.
    case putObject(hash: DataObjectHash)
    /// What the store holds and how it has been asked since the server started.
    case status
    /// Removes one entry: a poisoned entry stays until it is evicted or purged. A writer
    /// could overwrite any entry anyway, so a purge asks for write access and no more.
    case purge(key: CacheKey)
    /// Removes every entry and every object.
    case purgeAll
}

public enum CacheResponse: Codable, Equatable, Sendable {
    /// A hit: the entry's bytes are in the body, `cost` is what it recorded, and `objects`
    /// are the objects it holds with their sizes, as the server holds them. A client weighs
    /// the bytes of the ones it lacks against the cost before it fetches any of them.
    case entry(cost: Int, objects: [CachedObject])
    /// No entry under the key, or no object under the hash.
    case miss
    /// An entry or an object is filed.
    case stored
    /// The hashes asked about that the server does not hold.
    case missingObjects(hashes: [DataObjectHash])
    /// The object's bytes are in the body.
    case object
    case status(CacheServerStatus)
    /// How many entries a purge removed.
    case purged(entries: Int)
    case refused(reason: CacheRefusal)
}

/// Why the server would not do what a cache request asked. Each is a state the client can
/// act on, so each is a case of its own and none is a sentence to be read back.
public enum CacheRefusal: Codable, Equatable, Sendable {
    /// No accepted `hello` on this connection yet: the server does not know which message
    /// set the client speaks, nor what it may do.
    case helloRequired
    /// The connection may read and was asked to write.
    case readOnly
    /// A `putObject` body hashes to `actual`, not the hash it was sent under.
    case hashMismatch(declared: DataObjectHash, actual: DataObjectHash)
    /// A `putEntry` body is not as long as the request says.
    case lengthMismatch(declared: Int, received: Int)
    /// A `putEntry` references objects the server does not hold.
    case objectsMissing(hashes: [DataObjectHash])
    /// A hash that is not one the object store files anything under: hex digits, two to a
    /// byte, at most a SHA-256's worth.
    case notAnObjectHash(hash: String)
}

/// What `semel-cache status` prints, as the running server answers it.
public struct CacheServerStatus: Codable, Equatable, Sendable {
    public let entries: Int
    /// The bytes of the objects the entries hold, each object once: what the limit is
    /// held to.
    public let bytes: ByteCount
    public let limit: ByteCount
    /// `getEntry` requests answered with an entry, and with a miss, since the server
    /// started.
    public let hits: Int
    public let misses: Int

    public init(entries: Int, bytes: ByteCount, limit: ByteCount, hits: Int, misses: Int) {
        self.entries = entries
        self.bytes   = bytes
        self.limit   = limit
        self.hits    = hits
        self.misses  = misses
    }
}

extension CacheRequest {

    /// Whether answering changes the store, and so needs a connection granted write.
    public var writes: Bool {
        switch self {
        case .putEntry, .putObject, .purge, .purgeAll:
            return true
        case .getEntry, .hasObjects, .getObject, .status:
            return false
        }
    }
}
