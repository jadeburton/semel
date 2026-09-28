//
//  HeldSettlesTests.swift
//  SemelCLITests
//
//  B-129. What a `build` prints of its settles once its waits are over: one summary, and
//  under it one artifact diff, from before the first settle to after the last.
//

@testable import SemelCLI
import XCTest

final class HeldSettlesTests: XCTestCase {

    /// The summary first and the diff indented under it: the order the tutorial's
    /// transcripts show, and the one the diff's indentation assumes.
    func test_theDiffPrintsUnderTheSummary() {
        var held = HeldSettles()
        held.add(scheduled: 5, computed: 5, fromCache: 0, errors: 3)
        held.add(scheduled: 4, computed: 3, fromCache: 1, errors: 0)
        held.addDiff(appeared: ["output:/hello/hello"], changed: [], disappeared: [])

        XCTAssertEqual(held.lines, ["✅ 9 nodes scheduled, 8 computed, 1 from cache, 0 errors",
                                    "   appeared: output:/hello/hello"])
    }

    /// A settle that did no work prints no summary, and a diff with no summary above it
    /// still prints: a product that moved is news either way.
    func test_aDiffWithNoWorkPrintsAlone() {
        var held = HeldSettles()
        held.addDiff(changed: ["output:/lib.a"])

        XCTAssertEqual(held.lines, ["   changed: output:/lib.a"])
    }

    func test_nothingHeldPrintsNothing() {
        XCTAssertEqual(HeldSettles().lines, [])
    }

    /// The first kind says whether the reader had the product before the build, the last
    /// whether they have it after.
    func test_severalSettlesComeToOneDiff() {
        var held = HeldSettles()
        held.addDiff(appeared: ["output:/new", "output:/brief"], changed: ["output:/edited", "output:/removed"])
        held.addDiff(changed: ["output:/new", "output:/edited"], disappeared: ["output:/brief", "output:/removed"])

        XCTAssertEqual(held.lines, ["   appeared: output:/new",
                                    "   changed: output:/edited",
                                    "   disappeared: output:/removed"])
    }

    /// Gone and back within one build is said as changed: the client sees no hashes, so
    /// it cannot know the bytes are the same.
    func test_aProductThatWentAndCameBackIsChanged() {
        var held = HeldSettles()
        held.addDiff(disappeared: ["output:/app"])
        held.addDiff(appeared: ["output:/app"])

        XCTAssertEqual(held.lines, ["   changed: output:/app"])
    }
}

private extension HeldSettles {

    mutating func addDiff(appeared: [String] = [], changed: [String] = [], disappeared: [String] = []) {
        add(appeared: appeared, changed: changed, disappeared: disappeared)
    }
}
