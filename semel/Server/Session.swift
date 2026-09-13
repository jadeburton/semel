// Session.swift
// SemelServ
//
// What the server remembers about one connection: whether it asked for events, and how
// many batches it has open. In one process there is exactly one; with a socket there is
// one per connection, and tearing it down unwinds its batches so a client killed
// mid-push cannot leave the engine's work signals suppressed forever.

import Foundation

public final class Session {

    public var isSubscribed = false

    public private(set) var openBatchDepth = 0

    public init() {}

    func batchOpened() {
        openBatchDepth += 1
    }

    /// A close without an open is a client bug, not a reason to underflow.
    func batchClosed() {
        openBatchDepth = max(0, openBatchDepth - 1)
    }
}
