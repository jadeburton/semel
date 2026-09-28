//
//  SharedCounter.swift
//  SemelDatabaseModels
//

import Foundation

/// A count bumped from whichever thread does the work: the test observables that state a
/// cost as a number of round trips or rebuilds (`WireDataAccess.rowsRead`,
/// `Folder.manifestRebuildCount`). Each node computes on a thread of its own, so a plain
/// `static var` bumped with `+=` is a data race — updates lost at best, and undefined in
/// Swift's exclusivity model.
public final class SharedCounter: @unchecked Sendable {

    private let lock = NSLock()
    private var count = 0

    public init() {
    }

    public var value: Int {
        lock.withLock { count }
    }

    public func add(_ amount: Int) {
        lock.withLock { count += amount }
    }

    public func increment() {
        add(1)
    }

    public func reset() {
        lock.withLock { count = 0 }
    }
}
