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

    /// Blocks until the reply to this request arrives. Thread-safe.
    func send(_ request: Request, body: Data?) throws -> (Response, Data?)

    /// Called for every event the server pushes, from whatever thread the connection
    /// receives on. Nil discards events.
    var onEvent: ((Event) -> Void)? { get set }
}
