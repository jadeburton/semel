// PopulationQueueAndFetchPolicyTests.swift
// SemelCacheTests
//
// B-153, phase 3. The two values a shared cache's client keeps: the queue of what it has
// still to write, held to a count and to bytes, dropping its oldest; and the fetch policy,
// which weighs an entry's recorded cost against the bytes it lacks over the link's rate.

import Foundation
import SemelCache
import XCTest

final class PopulationQueueTests: XCTestCase {

    private func item(_ name: String, bytes: Int = 10) -> PopulationItem {
        PopulationItem(key: CacheKey(hash: name), cost: 1, objects: [], content: Data(repeating: 0x2E, count: bytes))
    }

    func test_itemsComeOutOldestFirst() {
        var queue = PopulationQueue(capacity: PopulationQueue.Capacity(items: 10, bytes: 1_000))
        queue.append(item("first"))
        queue.append(item("second"))

        XCTAssertEqual(queue.removeFirst()?.key.hash, "first")
        XCTAssertEqual(queue.removeFirst()?.key.hash, "second")
        XCTAssertNil(queue.removeFirst())
    }

    func test_aQueueAtItsCountDropsItsOldest() {
        var queue = PopulationQueue(capacity: PopulationQueue.Capacity(items: 2, bytes: 1_000))

        XCTAssertEqual(queue.append(item("first")), 0)
        XCTAssertEqual(queue.append(item("second")), 0)
        XCTAssertEqual(queue.append(item("third")), 1)

        XCTAssertEqual(queue.items.map(\.key.hash), ["second", "third"])
    }

    func test_aQueueAtItsBytesDropsAsManyAsItTakes() {
        var queue = PopulationQueue(capacity: PopulationQueue.Capacity(items: 100, bytes: 100))
        queue.append(item("first", bytes: 40))
        queue.append(item("second", bytes: 40))

        XCTAssertEqual(queue.append(item("large", bytes: 90)), 2)
        XCTAssertEqual(queue.items.map(\.key.hash), ["large"])
        XCTAssertEqual(queue.bytes, 90)
    }

    /// An item larger than the whole queue cannot wait in it.
    func test_anItemOverTheBytesAloneIsDroppedItself() {
        var queue = PopulationQueue(capacity: PopulationQueue.Capacity(items: 100, bytes: 100))

        XCTAssertEqual(queue.append(item("huge", bytes: 101)), 1)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.bytes, 0)
    }
}

final class CacheFetchPolicyTests: XCTestCase {

    func test_untilAFetchIsMeasuredTheRateIsAGigabitLinks() {
        let policy = CacheFetchPolicy()

        XCTAssertTrue(policy.isAssumed)
        XCTAssertEqual(policy.bytesPerSecond, 100_000_000)
        XCTAssertEqual(policy.secondsPerRequest, 0)
        XCTAssertEqual(policy.estimatedMilliseconds(objects: 1, bytes: 1_000_000), 10, accuracy: 0.001)
    }

    /// The quickest fetch is a request's own cost, and the large fetches, less it, are the
    /// link's rate: small objects alone measure the round trip and leave the rate assumed.
    func test_aRequestsCostAndTheLinksRateAreMeasuredApart() {
        var policy = CacheFetchPolicy()
        policy.record(CacheFetchPolicy.Sample(bytes: 2_000, seconds: 0.001))
        XCTAssertEqual(policy.secondsPerRequest, 0.001, accuracy: 0.000_001)
        XCTAssertTrue(policy.isAssumed, "a 2 KB fetch is a round trip, not a rate")

        policy.record(CacheFetchPolicy.Sample(bytes: 1_000_000, seconds: 0.501))
        policy.record(CacheFetchPolicy.Sample(bytes: 1_000_000, seconds: 1.501))

        XCTAssertFalse(policy.isAssumed)
        XCTAssertEqual(policy.bytesPerSecond, 1_000_000, accuracy: 0.001)
        XCTAssertEqual(policy.estimatedMilliseconds(objects: 2, bytes: 1_000_000), 1_002, accuracy: 0.001)
    }

    func test_onlyTheLastFetchesAreKept() {
        var policy = CacheFetchPolicy()
        policy.record(CacheFetchPolicy.Sample(bytes: 1, seconds: 0.000_1))
        for _ in 0..<CacheFetchPolicy.sampleCount {
            policy.record(CacheFetchPolicy.Sample(bytes: 100_000, seconds: 1))
        }

        XCTAssertEqual(policy.samples.count, CacheFetchPolicy.sampleCount)
        XCTAssertEqual(policy.secondsPerRequest, 1, "the quick fetch has been forgotten")
    }

    /// A build that cost a millisecond, over a link whose requests take a second, is rebuilt
    /// rather than fetched; a costly build is fetched over the same link; and an entry whose
    /// objects are all here already is always taken.
    func test_aCheapEntryOverASlowLinkIsRebuilt() {
        var policy = CacheFetchPolicy()
        policy.record(CacheFetchPolicy.Sample(bytes: 1_000, seconds: 1))

        XCTAssertFalse(policy.shouldFetch(objects: 1, bytes: 10_000, cost: 1))
        XCTAssertTrue(policy.shouldFetch(objects: 1, bytes: 10_000, cost: 60_000))
        XCTAssertTrue(policy.shouldFetch(objects: 0, bytes: 0, cost: 0))
    }

    /// Small objects over a fast link cost their round trips and nearly nothing for their
    /// bytes, so a build of a few milliseconds is still worth fetching.
    func test_overAFastLinkAnOrdinaryHitIsTaken() {
        var policy = CacheFetchPolicy()
        policy.record(CacheFetchPolicy.Sample(bytes: 3_000, seconds: 0.000_3))

        XCTAssertTrue(policy.shouldFetch(objects: 3, bytes: 600_000, cost: 15))
        XCTAssertTrue(CacheFetchPolicy().shouldFetch(objects: 1, bytes: 2_000_000, cost: 40))
    }
}
