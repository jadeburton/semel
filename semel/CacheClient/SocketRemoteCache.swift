// SocketRemoteCache.swift
// SemelCacheClient
//
// `RemoteCache` over TCP: the cache role's requests as frames on the transport's
// `SocketConnection`, which is the one implementation of the wire every client uses. This is
// the only place an engine's shared cache meets a frame; the engine sees `SharedCache` and
// the protocol `SemelCache` declares, and the engine's server installs this conformance
// from what the home names.

import Foundation
import SemelCache
import SemelNodeKit
import SemelProtocol
import SemelTransport

public final class SocketRemoteCache: RemoteCache {

    /// How long a request may go unanswered before the connection is given up, beside the
    /// time its bytes take at `slowestBytesPerSecond`. A lookup is made on a node's
    /// processing path, so a server that stops answering without closing — a machine that
    /// went to sleep, a cable pulled — must cost a bounded wait and then be a miss; closing
    /// the connection is what fails every request on it at once, and the queue's thread
    /// opens another.
    public static let requestDeadline: TimeInterval = 15

    /// The rate an object's transfer is given time for: 1 MB a second, far below any link
    /// a shared cache is worth using over, so a large object on a slow link is not cut off
    /// while it is still arriving.
    public static let slowestBytesPerSecond = 1_000_000.0

    public let server: CacheAddress
    private let connectTimeout: TimeInterval
    private let deadline: TimeInterval
    private let lock = NSLock()
    private var connection: SocketConnection?

    public convenience init(server: CacheAddress) {
        self.init(server: server, connectTimeout: 5, requestDeadline: Self.requestDeadline)
    }

    /// With the waits named: a test's server that never answers should not take 15 s to say
    /// so.
    public init(server: CacheAddress, connectTimeout: TimeInterval, requestDeadline: TimeInterval) {
        self.server         = server
        self.connectTimeout = connectTimeout
        self.deadline       = requestDeadline
    }

    public var address: String {
        server.description
    }

    // MARK: - The connection

    public func connect(identity: String?) throws -> RemoteCacheAccess {
        disconnect()
        let opened: SocketConnection
        do {
            opened = try SocketConnection.connect(to: .tcp(host: server.host, port: server.port), timeout: connectTimeout)
        } catch {
            throw RemoteCacheError.unreachable(address: address, reason: "\(error)")
        }
        let reply: Response
        do {
            reply = try send(.hello(Hello(role: .cache, wantsWrite: true, identity: identity)), body: nil, on: opened,
                             deadline: deadline).0
        } catch {
            opened.close()
            throw error
        }
        switch reply {
        case .hello(.cacheAccepted(let access)):
            lock.withLock { connection = opened }
            switch access {
            case .readWrite: return .readWrite
            case .readOnly:  return .readOnly
            }
        case .hello(.rejected(let reason)):
            opened.close()
            throw RemoteCacheError.rejected(reason: Self.describe(reason))
        default:
            opened.close()
            throw RemoteCacheError.unexpectedReply(reason: "\(reply) in answer to hello")
        }
    }

    public func disconnect() {
        let closing = lock.withLock { () -> SocketConnection? in
            defer { connection = nil }
            return connection
        }
        closing?.close()
    }

    private static func describe(_ rejection: HelloRejection) -> String {
        switch rejection {
        case .versionMismatch(let client, let server):
            return "this engine speaks protocol \(client) and the cache \(server)"
        case .roleNotOffered(let role):
            return "the server at that address is not a cache (it does not offer the \(role.rawValue) role)"
        }
    }

    // MARK: - Requests

    public func entry(forKey key: CacheKey) throws -> RemoteEntry? {
        let (reply, body) = try request(.getEntry(key: key), body: nil)
        switch reply {
        case .entry(let cost, let objects):
            return RemoteEntry(content: body ?? Data(), cost: cost, objects: objects)
        case .miss:
            return nil
        default:
            throw Self.unexpected(reply, to: "getEntry")
        }
    }

    public func missingObjects(among hashes: [DataObjectHash]) throws -> [DataObjectHash] {
        guard !hashes.isEmpty else {
            return []
        }
        let (reply, _) = try request(.hasObjects(hashes: hashes), body: nil)
        guard case .missingObjects(let missing) = reply else {
            throw Self.unexpected(reply, to: "hasObjects")
        }
        return missing
    }

    public func object(hash: DataObjectHash, expectedBytes: Int) throws -> Data? {
        let (reply, body) = try request(.getObject(hash: hash), body: nil, bytes: expectedBytes)
        switch reply {
        case .object:
            return body ?? Data()
        case .miss:
            return nil
        default:
            throw Self.unexpected(reply, to: "getObject")
        }
    }

    public func putObject(hash: DataObjectHash, bytes: Data) throws {
        let (reply, _) = try request(.putObject(hash: hash), body: bytes, bytes: bytes.count)
        guard case .stored = reply else {
            throw Self.unexpected(reply, to: "putObject")
        }
    }

    public func putEntry(key: CacheKey, cost: Int, objects: [DataObjectHash], content: Data) throws {
        let (reply, _) = try request(.putEntry(key: key, cost: cost, objects: objects, length: content.count),
                                     body: content, bytes: content.count)
        guard case .stored = reply else {
            throw Self.unexpected(reply, to: "putEntry")
        }
    }

    /// A refusal is the server's word on this request and leaves the connection usable;
    /// any other reply is one the request cannot have.
    private static func unexpected(_ reply: CacheResponse, to request: String) -> RemoteCacheError {
        guard case .refused(let reason) = reply else {
            return .unexpectedReply(reason: "\(reply) in answer to \(request)")
        }
        return .refused(reason: "\(reason)")
    }

    /// One cache request on the open connection, its reply narrowed to the cache's.
    private func request(_ request: CacheRequest, body: Data?, bytes: Int = 0) throws -> (CacheResponse, Data?) {
        guard let open = lock.withLock({ connection }) else {
            throw RemoteCacheError.connectionLost(reason: "no connection is open")
        }
        let allowed = deadline + Double(bytes) / Self.slowestBytesPerSecond
        let (reply, replyBody) = try send(.cache(request), body: body, on: open, deadline: allowed)
        switch reply {
        case .cache(let response):
            return (response, replyBody)
        case .error(.cacheStoreFailed(let description)):
            throw RemoteCacheError.storeFailed(reason: description)
        default:
            throw RemoteCacheError.unexpectedReply(reason: "\(reply)")
        }
    }

    /// Sends and waits at most `deadline`: past it the connection is closed, which ends the
    /// wait with the connection's own failure.
    private func send(_ request: Request, body: Data?, on open: SocketConnection,
                      deadline: TimeInterval) throws -> (Response, Data?) {
        let expired = ExpiryFlag()
        let watchdog = DispatchWorkItem {
            expired.set()
            open.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            return try open.send(request, body: body)
        } catch {
            let reason = expired.isSet ? String(format: "no answer within %g s", deadline) : "\(error)"
            throw RemoteCacheError.connectionLost(reason: reason)
        }
    }

    /// Whether a request's deadline passed, set by the watchdog that closed its connection.
    private final class ExpiryFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false

        func set() {
            lock.withLock { expired = true }
        }

        var isSet: Bool {
            lock.withLock { expired }
        }
    }
}
