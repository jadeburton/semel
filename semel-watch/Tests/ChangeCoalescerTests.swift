//
//  ChangeCoalescerTests.swift
//  SemelWatchTests
//
//  B-126. A burst of saves is one batch, handed over once the disk has been quiet for the
//  interval — on the test's clock, so two seconds cost nothing here.
//

import SemelNodeKit
@testable import SemelWatch
import XCTest

final class ChangeCoalescerTests: XCTestCase {

    private func changed(_ paths: String...) -> [FileEvent] {
        paths.map { FileEvent(path: Path($0)) }
    }

    /// Every report restarts the interval: a checkout's paths arriving over several seconds
    /// are one batch, due two seconds after the last of them.
    func test_aBurstIsOneBatch() {
        var coalescer = ChangeCoalescer(quietInterval: .seconds(2))

        coalescer.record(changed("a.c"), at: .zero)
        coalescer.record(changed("b.c"), at: .milliseconds(1500))
        coalescer.record(changed("c/d.c"), at: .seconds(3))

        XCTAssertNil(coalescer.takeBatch(at: .milliseconds(4999)))
        XCTAssertEqual(coalescer.takeBatch(at: .seconds(5)),
                       ChangeBatch(changed: ["a.c", "b.c", "c/d.c"]))
        XCTAssertNil(coalescer.takeBatch(at: .seconds(10)), "what was handed over is not held")
    }

    /// What arrives while a batch is being pushed waits for a quiet interval of its own,
    /// and is the next batch: nothing is dropped, and nothing joins the batch under way.
    func test_anEventDuringABatchStartsTheNext() {
        var coalescer = ChangeCoalescer(quietInterval: .seconds(2))
        coalescer.record(changed("a.c"), at: .zero)
        let first = coalescer.takeBatch(at: .seconds(2))

        coalescer.record(changed("b.c"), at: .milliseconds(2500))

        XCTAssertEqual(first, ChangeBatch(changed: ["a.c"]))
        XCTAssertNil(coalescer.takeBatch(at: .seconds(4)))
        XCTAssertEqual(coalescer.takeBatch(at: .milliseconds(4500)), ChangeBatch(changed: ["b.c"]))
    }

    /// A file saved twice in a burst — or reported by a save's temporary file and its
    /// rename — is pushed once, with what is on disk when the batch is planned.
    func test_aPathReportedTwiceIsInTheBatchOnce() {
        var coalescer = ChangeCoalescer(quietInterval: .seconds(2))

        coalescer.record(changed("a.c", "a.c"), at: .zero)
        coalescer.record(changed("a.c"), at: .seconds(1))

        XCTAssertEqual(coalescer.takeBatch(at: .seconds(3))?.changed, ["a.c"])
    }

    /// The interval is read on the caller's clock: due exactly one interval after the last
    /// report, whatever the wall says, and nothing is due while nothing is held.
    func test_theQuietIntervalIsTheCallersClockNotTheWalls() {
        var coalescer = ChangeCoalescer(quietInterval: .milliseconds(300))
        XCTAssertNil(coalescer.dueAt)
        XCTAssertNil(coalescer.takeBatch(at: .seconds(1000)))

        coalescer.record(changed("a.c"), at: .seconds(1000))

        XCTAssertEqual(coalescer.dueAt, .milliseconds(1_000_300))
        XCTAssertNil(coalescer.takeBatch(at: .milliseconds(1_000_299)))
        XCTAssertNotNil(coalescer.takeBatch(at: .milliseconds(1_000_300)))
    }

    /// A subtree the stream lost track of is kept apart from the paths it reported, so the
    /// planner pushes it whole.
    func test_aRescanIsKeptApartFromTheChangedPaths() {
        var coalescer = ChangeCoalescer(quietInterval: .seconds(2))

        coalescer.record([FileEvent(path: "src", needsRescan: true), FileEvent(path: "a.c")], at: .zero)

        XCTAssertEqual(coalescer.takeBatch(at: .seconds(2)), ChangeBatch(changed: ["a.c"], rescanned: ["src"]))
    }

    /// Path order, segment by segment: a folder's own paths sort together.
    func test_aBatchIsInPathOrder() {
        var coalescer = ChangeCoalescer(quietInterval: .seconds(2))

        coalescer.record(changed("a-b", "z.c", "a/b"), at: .zero)

        XCTAssertEqual(coalescer.takeBatch(at: .seconds(2))?.changed, ["a/b", "a-b", "z.c"])
    }
}
