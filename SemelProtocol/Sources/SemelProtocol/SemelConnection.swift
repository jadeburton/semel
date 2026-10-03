// SemelConnection.swift
// SemelProtocol
//
// What a client holds: a thing that carries a request and returns the reply matched to
// it. `send` is synchronous — it blocks the calling thread until its own reply arrives,
// and several threads may have sends outstanding at once, because the REPL, the command
// plugins and the engine's cache hooks are all synchronous and an async surface would push
// `async` through every one of them. A command with many requests to make in a row and
// work of its own between them — a push, reading the next files from disk — sends without
// waiting instead (`sendWithoutWaiting`) and collects each reply when it needs it, still on
// one thread. Request matching lives inside the conformers, so an async variant is a
// change to these signatures and their conformers, never to a plugin.
//
// It lives here rather than in the CLI because the in-process conformer holds the
// server's request handler; a protocol owned by the CLI would force the CLI and the
// server to import each other.

import Foundation

public protocol SemelConnection: AnyObject {

    /// Blocks until the last frame of the reply to this request arrives, and returns it.
    /// Thread-safe.
    ///
    /// A reply that streams (B-137, on `DaemonResponse`) arrives in parts first: each is
    /// handed to `onPart`, in the order the server sent them, on the calling thread, before
    /// the next is read. What is returned is then only the last part. The first error
    /// `onPart` throws is kept, the rest of the reply is still read so the connection stays
    /// in step, and the error is thrown in place of the reply.
    ///
    /// A reply with no body arrives as `nil`; a request with no body may be sent as `nil`
    /// or empty, and a conformer treats the two alike. Parts carry no body.
    func send(_ request: Request, body: Data?, onPart: (Response) throws -> Void) throws -> (Response, Data?)

    /// Sends the request and returns at once, with a handle that blocks for the reply when
    /// asked: so a caller can have several requests in flight and do its own work while
    /// the server answers them. A reply that streams is collected whole, its parts joined,
    /// as `send(_:body:)` returns it. Thread-safe.
    ///
    /// The server handles a connection's requests in the order they arrive, so a caller
    /// that collects its replies in the order it sent the requests reads them as though it
    /// had waited for each in turn. Throws now only for a request that could not leave;
    /// whatever became of one that did is thrown by `PendingReply.reply()`.
    ///
    /// A conformer with nothing to overlap answers before it returns, which is what the
    /// default does: it sends with `send` and hands back the answer it already has.
    func sendWithoutWaiting(_ request: Request, body: Data?) throws -> PendingReply

    /// Called for every event the server pushes, from whatever thread the connection
    /// receives on. Nil discards events.
    var onEvent: ((Event) -> Void)? { get set }
}

extension SemelConnection {

    /// The whole reply, however many frames it took: the parts of a streamed one joined in
    /// order, so a caller that wants the answer as one value never sees the streaming. The
    /// price is the whole answer in memory at once — a refusal is what it replaces.
    public func send(_ request: Request, body: Data?) throws -> (Response, Data?) {
        var parts = ReplyParts()
        let (last, replyBody) = try send(request, body: body, onPart: { try parts.append($0) })
        return (try parts.whole(endingWith: last), replyBody)
    }

    /// Answered before it returns: a connection whose `send` does the work on the calling
    /// thread, as the in-process one does, has nothing to overlap it with.
    public func sendWithoutWaiting(_ request: Request, body: Data?) throws -> PendingReply {
        PendingReply(answered: Result { try send(request, body: body) })
    }
}

/// The reply to a request sent without waiting (`SemelConnection.sendWithoutWaiting`).
/// `reply()` blocks until it has come, and may be asked again, from any thread, for the
/// same answer. A handle dropped without asking leaves its reply to arrive and be
/// discarded; the connection stays in step either way, because replies are matched to
/// requests by correlation ID and not by their order.
public final class PendingReply {

    private enum State {
        case awaited(() throws -> (Response, Data?))
        case answered(Result<(Response, Data?), Error>)
    }

    private let lock = NSLock()
    private var state: State

    /// A reply still to come: `collect` blocks until it has, and is run once.
    public init(collecting collect: @escaping () throws -> (Response, Data?)) {
        state = .awaited(collect)
    }

    /// A reply that is already in.
    public init(answered outcome: Result<(Response, Data?), Error>) {
        state = .answered(outcome)
    }

    /// The whole reply, a streamed one joined; blocks until it has arrived.
    public func reply() throws -> (Response, Data?) {
        try lock.withLock { () throws -> (Response, Data?) in
            switch state {
            case .answered(let outcome):
                return try outcome.get()
            case .awaited(let collect):
                let outcome = Result { try collect() }
                state = .answered(outcome)
                return try outcome.get()
            }
        }
    }
}
