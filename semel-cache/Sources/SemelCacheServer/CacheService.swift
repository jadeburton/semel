// CacheService.swift
// SemelCacheServer
//
// What a cache server does with one connection: the hello that says which message set the
// client speaks and whether it means to write, then the cache's requests, each checked
// against what the hello granted before the store is asked. Nothing else: a daemon's
// request is refused by role, and no event is ever sent.
//
// `CacheRequestHandler` is the whole of it with no socket, which is what the tests drive;
// `CacheService` is the same handler behind `SemelTransport`'s listener.

import Foundation
import SemelProtocol
import SemelTransport

/// What one connection has been granted: nothing until an accepted hello.
public final class CacheSession {
    /// Read and written on the connection's preparing queue only, in arrival order.
    public internal(set) var access: CacheAccess?
    /// The name the client's hello gave, nil when it gave none. Kept for the writers' list a
    /// deployment will need; `--writers all` and `none` decide without it.
    public internal(set) var identity: String?

    public init() {}
}

public struct CacheRequestHandler {

    public let store: CacheServerStore
    public let writers: CacheWriters

    public init(store: CacheServerStore, writers: CacheWriters) {
        self.store   = store
        self.writers = writers
    }

    /// Answers `request` to the end, waiting for its write when it has one.
    public func handle(_ request: Request, body: Data?, session: CacheSession) -> (Response, Data?) {
        store.complete(prepare(request, body: body, session: session))
    }

    /// The part of answering that runs in arrival order: the hello's grant, the checks
    /// against it, and the store's work. What is left is waiting for a write (`complete`).
    public func prepare(_ request: Request, body: Data?, session: CacheSession) -> CacheAnswer {
        switch request {
        case .hello(let hello):
            let answer = answer(hello)
            if case .cacheAccepted(let access) = answer {
                session.access   = access
                session.identity = hello.identity
            }
            return CacheAnswer(hello: answer)
        case .daemon:
            return CacheAnswer(error: .roleNotOffered(role: .daemon))
        case .cache(let cacheRequest):
            guard let access = session.access else {
                return CacheAnswer(.refused(reason: .helloRequired))
            }
            guard !cacheRequest.writes || access == .readWrite else {
                return CacheAnswer(.refused(reason: .readOnly))
            }
            return store.prepare(cacheRequest, body: body)
        }
    }

    /// A client is read-only unless it asked to write and the server's writers include it.
    private func answer(_ hello: Hello) -> HelloResponse {
        guard hello.protocolVersion == ProtocolVersion.current else {
            return .rejected(reason: .versionMismatch(client: hello.protocolVersion, server: ProtocolVersion.current))
        }
        guard hello.role == .cache else {
            return .rejected(reason: .roleNotOffered(role: hello.role))
        }
        let mayWrite = hello.wantsWrite && writers == .all
        return .cacheAccepted(access: mayWrite ? .readWrite : .readOnly)
    }
}

/// One connection of the listener. Its requests are prepared in arrival order and answered
/// in the same order, a `putEntry` once its write is in the log; the next request is
/// prepared meanwhile, which is what lets one client's writes share a batch.
public final class CacheService: ConnectionService {

    private let handler: CacheRequestHandler
    private let session = CacheSession()

    public init(handler: CacheRequestHandler) {
        self.handler = handler
    }

    public var receivesEvents: Bool {
        false
    }

    public func prepare(_ request: Request, body: Data?) -> PreparedAnswer {
        let answer = handler.prepare(request, body: body, session: session)
        return PreparedAnswer(blocks: false) { [store = handler.store] _ in
            store.complete(answer)
        }
    }

    public func connectionEnded() {}
}
