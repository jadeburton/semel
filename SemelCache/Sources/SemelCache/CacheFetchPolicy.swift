// CacheFetchPolicy.swift
// SemelCache
//
// Whether a hit on a shared cache is worth taking (B-153). An entry records what its build
// cost; fetching it costs a request per object this machine lacks and their bytes over
// whatever the link moves. When the fetch would take longer than the build did, the engine
// builds instead — the answer is the same either way, so the choice is about time and never
// about what a build computes.

import Foundation

/// The link as the last fetches measured it — what a request costs however small it is, and
/// the rate the large ones moved at — and the decision it makes.
///
/// Two figures rather than one rate, because most objects are small: a few kilobytes take
/// about a request's round trip whatever the link's bandwidth, so a rate taken over them
/// alone reads a fast link as a slow one and declines every hit with a large object.
///
/// A value: `SharedCache` keeps one under its lock and records into it after each fetch.
public struct CacheFetchPolicy: Equatable, Sendable {

    /// The rate assumed until an object large enough to measure one has been fetched: 100 MB
    /// a second, a gigabit Ethernet's payload rounded down. The first deployment is a LAN
    /// (the 2026-10-11 design), and a gigabit link is the slowest wired one it has, so until
    /// a fetch has measured the link the estimate is what that link would do — at which a
    /// megabyte costs 10 ms, under what nearly any tool's run costs, and nearly every hit is
    /// taken. A slower link shows itself in the first large fetches, and the measurement
    /// replaces this.
    public static let assumedBytesPerSecond = 100_000_000.0

    /// The smallest fetch a rate is measured from: below it the round trip is most of the
    /// time, and the bytes say little about the link.
    public static let smallestMeasuredBytes = 64 * 1_024

    /// How many fetched objects the measurements are taken over.
    public static let sampleCount = 32

    /// One fetched object: its bytes and the seconds from asking to holding them.
    public struct Sample: Equatable, Sendable {
        public let bytes: Int
        public let seconds: Double

        public init(bytes: Int, seconds: Double) {
            self.bytes   = bytes
            self.seconds = seconds
        }
    }

    /// The last `sampleCount` fetches, oldest first.
    public private(set) var samples: [Sample] = []

    public init() {}

    /// Records one fetch, forgetting the oldest beyond `sampleCount`.
    public mutating func record(_ sample: Sample) {
        samples.append(sample)
        if samples.count > Self.sampleCount {
            samples.removeFirst(samples.count - Self.sampleCount)
        }
    }

    /// What a request costs however small: the quickest recorded fetch, which is as near to
    /// a bare round trip as the samples come. None before anything has been fetched.
    public var secondsPerRequest: Double {
        samples.map(\.seconds).min() ?? 0
    }

    /// The rate the large fetches moved at once a request's own cost is taken off them; the
    /// assumed rate until one has been fetched.
    public var bytesPerSecond: Double {
        let large   = samples.filter { $0.bytes >= Self.smallestMeasuredBytes }
        let bytes   = large.reduce(0) { $0 + $1.bytes }
        let seconds = large.reduce(0.0) { $0 + max(0, $1.seconds - secondsPerRequest) }
        guard bytes > 0, seconds > 0 else {
            return Self.assumedBytesPerSecond
        }
        return Double(bytes) / seconds
    }

    /// Whether the rate is the assumed one rather than a measurement.
    public var isAssumed: Bool {
        !samples.contains { $0.bytes >= Self.smallestMeasuredBytes }
    }

    /// Milliseconds that fetching `objects` objects of `bytes` in all is expected to take.
    public func estimatedMilliseconds(objects: Int, bytes: Int) -> Double {
        (Double(objects) * secondsPerRequest + Double(bytes) / bytesPerSecond) * 1000.0
    }

    /// Whether to fetch `objects` objects of `bytes` for an entry whose build cost `cost`
    /// milliseconds: yes unless the fetch is expected to take longer. Nothing to fetch is
    /// always taken.
    public func shouldFetch(objects: Int, bytes: Int, cost: Int) -> Bool {
        guard objects > 0 else {
            return true
        }
        return estimatedMilliseconds(objects: objects, bytes: bytes) <= Double(cost)
    }
}
