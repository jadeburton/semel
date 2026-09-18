//
//  EnvironmentTests.swift
//  SemelEndToEndTests
//

import XCTest

final class EnvironmentTests: XCTestCase {

    /// `newRoot` sweeps `/tmp/semel-tests` for entries an earlier run left behind. A
    /// stale one (older than the day-long grace period) must go; anything fresher,
    /// including a run someone is still inspecting, must not be touched.
    func test_newRootRemovesSiblingsOlderThanADayButKeepsFresherOnes() throws {
        let base = URL(fileURLWithPath: "/tmp/semel-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let stale = base.appendingPathComponent("stale-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let twoDaysAgo = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        try FileManager.default.setAttributes(
            [.creationDate: twoDaysAgo, .modificationDate: twoDaysAgo], ofItemAtPath: stale.path)

        let fresh = base.appendingPathComponent("fresh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: fresh)
        }

        let root = try EndToEndEnvironment.newRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}
