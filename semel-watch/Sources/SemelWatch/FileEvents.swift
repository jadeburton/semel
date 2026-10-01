// FileEvents.swift
// SemelWatch
//
// What a stream of changes on disk yields, and the clock the watcher reads it by. Both are
// protocols so that everything above them — the filter, the coalescer, the planner and
// the loop — runs in a test with events fed by hand and time moved by hand (B-126).

import Foundation
import SemelNodeKit

/// One path a stream reported, relative to the base.
public struct FileEvent: Equatable {
    public let path: Path
    /// The stream lost track below `path` — FSEvents' must-scan-subdirectories, or a
    /// history it could not deliver — so what changed there is not known path by path,
    /// and the whole subtree is pushed again.
    public let needsRescan: Bool

    public init(path: Path, needsRescan: Bool = false) {
        self.path        = path
        self.needsRescan = needsRescan
    }
}

/// What one wait on a stream came to.
public enum FileEventsYield: Equatable {
    /// Paths that changed, in the order the stream gave them.
    case events([FileEvent])
    /// The wait's limit passed with nothing reported.
    case timedOut
    /// The stream was stopped and has nothing more to give.
    case ended
}

/// A stream of changed paths under one base: FSEvents in `semel-watch`, a queue filled by
/// hand in a test. A conformer reports what changed and never what to do about it; the
/// disk is read again when the quiet interval ends, because a stream may coalesce, reorder
/// or deliver late, and what is on disk then is what a push would push.
public protocol FileEvents: AnyObject {
    /// Blocks until paths arrive, `timeout` passes, or the stream is stopped. A nil
    /// timeout waits for as long as it takes.
    func next(waitingAtMost timeout: Duration?) -> FileEventsYield

    /// Ends the stream: a wait under way returns `ended`, and every later one does.
    func stop()

    /// Whether `stop` has been called.
    var isStopped: Bool { get }
}

/// The time the watcher keeps: a reading since some fixed start, and a sleep. The wall's in
/// `semel-watch`; a test's moves only when the test says, so a quiet interval of two
/// seconds costs a test nothing.
public protocol WatchClock: AnyObject {
    var now: Duration { get }
    func sleep(for duration: Duration)
}

/// The monotonic clock: a reading the system's own time changes cannot move backwards.
public final class SystemWatchClock: WatchClock {
    private let start = ContinuousClock.now

    public init() {}

    public var now: Duration { ContinuousClock.now - start }

    public func sleep(for duration: Duration) {
        Thread.sleep(forTimeInterval: duration.timeInterval)
    }
}

extension Duration {
    /// Seconds, for the APIs that take a `TimeInterval`.
    public var timeInterval: TimeInterval {
        let (wholeSeconds, attoseconds) = components
        let attosecondsPerSecond = 1e18
        return Double(wholeSeconds) + Double(attoseconds) / attosecondsPerSecond
    }
}
