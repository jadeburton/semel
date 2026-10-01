// SemelConnection.swift
// SemelProtocol
//
// What a client holds: a thing that carries a request and returns the reply matched to
// it. Two members, on purpose. `send` is synchronous — it blocks the calling thread until
// its own reply arrives, and several threads may have sends outstanding at once, because
// the REPL, the command plugins and the engine's cache hooks are all synchronous and an
// async surface would push `async` through every one of them for a client that sends
// one request at a time. Request matching lives inside the conformers, so an async
// variant is a change to these two signatures and their conformers, never to a plugin.
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
}
