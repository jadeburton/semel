// Session.swift
// SemelServ
//
// What the server remembers about one connection: whether it asked for events, and how
// many batches it has open. In one process there is exactly one; with a socket there is
// one per connection, and tearing it down unwinds its batches so a client killed
// mid-push cannot leave the engine's work signals suppressed forever.

import Foundation

public final class Session {

    private let lock = NSLock()
    private var subscribed = false
    private var batchDepth = 0

    public init() {}

    /// Set on the handler's queue; read from whatever thread delivers an event.
    public var isSubscribed: Bool {
        get { lock.withLock { subscribed } }
        set { lock.withLock { subscribed = newValue } }
    }

    public var openBatchDepth: Int {
        lock.withLock { batchDepth }
    }

    func batchOpened() {
        lock.withLock { batchDepth += 1 }
    }

    /// A close without an open is a client bug, not a reason to underflow.
    func batchClosed() {
        lock.withLock { batchDepth = max(0, batchDepth - 1) }
    }
}
