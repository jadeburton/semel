// Session.swift
// SemelServer
//
// What the server remembers about one connection: whether it asked for events, how many
// batches it has open, and the journal of the one it has open. In one process there is
// exactly one; with a socket there is one per connection, and tearing it down commits its
// batch so a client killed mid-push cannot leave the engine's work signals suppressed
// forever.

import Foundation
import SemelCore

public final class Session {

    private let lock = NSLock()
    private var subscribed = false
    private var batchDepth = 0

    /// What names this session's journal rows in the graph: unique in the process, which
    /// is all a journal needs, since a server starting up drops every journal the process
    /// before it left (`BatchJournal.discardAll`).
    let identifier: String

    /// The journal of the batch this session has open, from its outermost `begin` to its
    /// outermost `commit`; nil between batches. Read and written on the handler's queue
    /// only, which is what serialises it.
    var journal: BatchJournal?

    public init() {
        identifier = UUID().uuidString
    }

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
