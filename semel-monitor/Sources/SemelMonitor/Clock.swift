// Clock.swift
// SemelMonitor
//
// What the planner reads the time from. The engine is a time-free zone; this app is where
// time lives — a result card's eight seconds — and it lives behind this protocol, so a test
// moves it by hand and never waits.

import Foundation

/// A reading of elapsed time, monotonic. Named for the design's word; inside this module
/// it shadows the standard library's generic `Clock`, which the planner has no use for.
public protocol Clock: AnyObject {
    var now: Duration { get }
}

/// The monotonic clock: a reading the system's own time changes cannot move backwards, as
/// the watcher's is.
public final class SystemClock: Clock {
    private let start = ContinuousClock.now

    public init() {}

    public var now: Duration { ContinuousClock.now - start }
}

extension Duration {
    /// Seconds, for the APIs that take a `TimeInterval`.
    public var timeInterval: TimeInterval {
        let (wholeSeconds, attoseconds) = components
        let attosecondsPerSecond = 1e18
        return Double(wholeSeconds) + Double(attoseconds) / attosecondsPerSecond
    }
}
