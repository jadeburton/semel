// ProgressReport.swift
// SemelCore
//
// Where the current settle stands, for a terminal to draw while it waits (B-95).
//
// The three totals are the `SettleTally`'s, read as the pass changes state, so what a
// progress line shows is what the settle summary will end with — not a sum of batches,
// which would count a node that ran twice as two. The engine hands one of these to
// `BuildEngine.progressReporter`; a server turns it into an event and the terminal into a
// line redrawn in place.

import SemelNodeKit

/// What one settle has done so far and what it is doing now.
public struct ProgressReport: Equatable, Sendable {

    /// Distinct nodes the settle has fetched as scheduled.
    public var scheduled = 0

    /// Of those, the ones whose latest result was one they ran themselves.
    public var computed = 0

    /// Of those, the ones whose latest result came from a cache entry.
    public var fromCache = 0

    /// Scheduled and not started: the queue ahead of the pass. It rises while the cascade
    /// is still generating work and falls as the pass drains it.
    public var pending = 0

    /// Started and not finished, in start order.
    public var running: [ActiveNodeDescription] = []

    public init(scheduled: Int = 0, computed: Int = 0, fromCache: Int = 0, pending: Int = 0,
                running: [ActiveNodeDescription] = []) {
        self.scheduled = scheduled
        self.computed  = computed
        self.fromCache = fromCache
        self.pending   = pending
        self.running   = running
    }
}

/// One node computing now, as a report names it: the type; what it is computed for, as its
/// error report would name it (B-145); the path it has, the project file it builds or the
/// file on its `input` port, empty when it has none of them; and its identity, the hash of
/// its spec, which tells two nodes of one type and one subject apart.
public struct ActiveNodeDescription: Equatable, Sendable {
    public let typeName: String
    public let name: String
    public let subject: ErrorDocument.Subject?
    public let identity: String

    public init(typeName: String, name: String, subject: ErrorDocument.Subject? = nil, identity: String = "") {
        self.typeName = typeName
        self.name     = name
        self.subject  = subject
        self.identity = identity
    }
}
