// ChangeCoalescer.swift
// SemelWatch
//
// Paths in, batches out after the disk has been quiet (B-126).

import SemelNodeKit

/// The paths of one burst: what one `begin` … `commit` is planned from.
public struct ChangeBatch: Equatable {
    /// Paths reported changed, each once, in path order.
    public let changed: [Path]
    /// Paths whose whole subtree is to be pushed again, each once, in path order.
    public let rescanned: [Path]

    public init(changed: [Path] = [], rescanned: [Path] = []) {
        self.changed   = changed
        self.rescanned = rescanned
    }

    public var isEmpty: Bool { changed.isEmpty && rescanned.isEmpty }
}

/// Collects what a stream reports until it has been quiet for the interval, then hands it
/// over as one batch.
///
/// An editor saves through a temporary file and a rename, a `git checkout` touches hundreds
/// of files, a generator writes a folder: each arrives as a burst, and the engine should
/// settle once for it, not once per path. So every report restarts the interval, and a
/// batch is due only when one whole interval has passed with none. A path reported twice is
/// in the batch once — it is read from the disk when the batch is planned, so its final
/// bytes are what is pushed. Paths reported while the previous batch is being pushed wait
/// for their own quiet interval; nothing is dropped.
///
/// Time is the caller's: every method takes the reading, so a test drives the interval
/// without waiting it out.
public struct ChangeCoalescer {

    public let quietInterval: Duration

    private var changed:   Set<Path> = []
    private var rescanned: Set<Path> = []
    private var lastReportAt: Duration?

    public init(quietInterval: Duration) {
        self.quietInterval = quietInterval
    }

    /// Adds what a stream reported at `now`, which starts the quiet interval again.
    public mutating func record(_ events: [FileEvent], at now: Duration) {
        guard !events.isEmpty else {
            return
        }
        for event in events {
            if event.needsRescan {
                rescanned.insert(event.path)
            } else {
                changed.insert(event.path)
            }
        }
        lastReportAt = now
    }

    /// When the batch held now is due, or nil when nothing is held.
    public var dueAt: Duration? {
        lastReportAt.map { $0 + quietInterval }
    }

    /// The batch, once the disk has been quiet for the interval at `now`; nil before then
    /// or when nothing is held. What it hands over it no longer holds.
    public mutating func takeBatch(at now: Duration) -> ChangeBatch? {
        guard let dueAt, now >= dueAt else {
            return nil
        }
        let batch = ChangeBatch(changed:   changed.sorted(by: Path.precedes),
                                rescanned: rescanned.sorted(by: Path.precedes))
        changed      = []
        rescanned    = []
        lastReportAt = nil
        return batch
    }
}

extension Path {
    /// Segment by segment, so a folder's own paths sort together: `a/b` before `a-b`,
    /// which a comparison of the joined strings would put the other way round.
    static func precedes(_ left: Path, _ right: Path) -> Bool {
        left.segments.lexicographicallyPrecedes(right.segments)
    }
}
