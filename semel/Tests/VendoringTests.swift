//
//  VendoringTests.swift
//  SemelCLITests
//

import Foundation
import SemelVendor
import XCTest

/// `semel-vendor` copies what SwiftPM resolved into the one place the converter looks:
/// `<root>/Dependencies/<name>`. The copy is the whole contract, so what it leaves out and
/// what it replaces are the things worth pinning.
final class VendoringTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-vendor-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var checkouts: URL    { root.appendingPathComponent(".build/checkouts", isDirectory: true) }
    private var dependencies: URL { root.appendingPathComponent("Dependencies", isDirectory: true) }

    private func write(_ relativePath: String, _ content: String = "x") throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path)
    }

    /// A checkout named like SwiftPM names it — `GRDB.swift`, not the lowercased identity —
    /// lands under the same name, source and manifest included, sorted by name.
    func test_copiesEveryCheckoutUnderItsOwnName() throws {
        try write(".build/checkouts/GRDB.swift/Package.swift")
        try write(".build/checkouts/GRDB.swift/GRDB/Database.swift")
        try write(".build/checkouts/Nuke/Package.swift")

        let copied = try Vendoring.copyCheckouts(from: checkouts, into: dependencies)

        XCTAssertEqual(copied.map(\.name), ["GRDB.swift", "Nuke"])
        XCTAssertTrue(exists("Dependencies/GRDB.swift/Package.swift"))
        XCTAssertTrue(exists("Dependencies/GRDB.swift/GRDB/Database.swift"))
        XCTAssertTrue(exists("Dependencies/Nuke/Package.swift"))
    }

    /// A checkout's `.git` is not source, and a nested repository would confuse every tool
    /// that walks the tree; `.build` is the dependency's own build output.
    func test_leavesOutGitAndBuildDirectories() throws {
        try write(".build/checkouts/Nuke/Package.swift")
        try write(".build/checkouts/Nuke/.git/HEAD")
        try write(".build/checkouts/Nuke/.build/junk")

        _ = try Vendoring.copyCheckouts(from: checkouts, into: dependencies)

        XCTAssertTrue(exists("Dependencies/Nuke/Package.swift"))
        XCTAssertFalse(exists("Dependencies/Nuke/.git"))
        XCTAssertFalse(exists("Dependencies/Nuke/.build"))
    }

    /// Running it again after a dependency changed must not leave stale files from the
    /// previous copy behind: the destination is replaced, not merged.
    func test_replacesAPreviousCopyRatherThanMergingIntoIt() throws {
        try write("Dependencies/Nuke/Sources/Old.swift")
        try write(".build/checkouts/Nuke/Sources/New.swift")

        _ = try Vendoring.copyCheckouts(from: checkouts, into: dependencies)

        XCTAssertTrue(exists("Dependencies/Nuke/Sources/New.swift"))
        XCTAssertFalse(exists("Dependencies/Nuke/Sources/Old.swift"))
    }

    /// Several packages vendored into one folder — one build root for a formula that
    /// includes them all — hold the union of their closures, one copy per name.
    func test_severalPackagesCanShareOneDependenciesFolder() throws {
        try write("A/.build/checkouts/Nuke/Package.swift")
        try write("A/.build/checkouts/SwiftSoup/Package.swift")
        try write("B/.build/checkouts/Nuke/Package.swift")
        try write("B/.build/checkouts/Bodega/Package.swift")
        let shared = root.appendingPathComponent("Dependencies", isDirectory: true)

        let fromA = try Vendoring.copyCheckouts(from: root.appendingPathComponent("A/.build/checkouts"), into: shared)
        let fromB = try Vendoring.copyCheckouts(from: root.appendingPathComponent("B/.build/checkouts"), into: shared)

        XCTAssertEqual(fromA.map(\.name), ["Nuke", "SwiftSoup"])
        XCTAssertEqual(fromB.map(\.name), ["Bodega", "Nuke"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shared.path).sorted(),
                       ["Bodega", "Nuke", "SwiftSoup"])
    }

    func test_saysWhenNothingWasResolved() {
        XCTAssertThrowsError(try Vendoring.copyCheckouts(from: checkouts, into: dependencies)) { error in
            XCTAssertTrue(String(describing: error).contains("swift package resolve"), "got \(error)")
        }
    }
}
