//
//  VendoringTests.swift
//  SemelCLITests
//

import Foundation
import SemelNodeKit
import SemelSwiftTool
import XCTest

/// `semel-swift` copies what SwiftPM resolved into the one place the converter looks:
/// `<root>/Dependencies/<name>`. The copy is the whole contract, so what it leaves out and
/// what it replaces are the things worth pinning.
final class VendoringTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-swift-tests/\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - What the resolver chose (B-06)

    /// The pins a lock records come from SwiftPM's resolved file, by the folder each
    /// checkout is under — the repository's name, not SwiftPM's lowercased identity.
    func test_readsThePinsOfAResolvedFileByCheckoutName() throws {
        try write("Package.resolved", """
            {
              "originHash" : "0f3e",
              "pins" : [
                {
                  "identity" : "grdb.swift",
                  "kind" : "remoteSourceControl",
                  "location" : "https://github.com/groue/GRDB.swift.git",
                  "state" : { "revision" : "b83108d10f42680d78f23fe4d4d80fc88dab3212", "version" : "7.11.1" }
                },
                {
                  "identity" : "nuke",
                  "kind" : "remoteSourceControl",
                  "location" : "https://github.com/kean/Nuke",
                  "state" : { "branch" : "main", "revision" : "0123abcd" }
                }
              ],
              "version" : 3
            }
            """)

        let pins = Vendoring.pins(inResolvedFileAt: root.appendingPathComponent("Package.resolved"))

        XCTAssertEqual(pins["GRDB.swift"], .init(origin: "https://github.com/groue/GRDB.swift.git", version: "7.11.1",
                                                 revision: "b83108d10f42680d78f23fe4d4d80fc88dab3212"))
        XCTAssertEqual(pins["Nuke"], .init(origin: "https://github.com/kean/Nuke", version: nil, revision: "0123abcd"),
                       "a branch pin has a revision and no version")
    }

    func test_noResolvedFileIsNoPins() {
        XCTAssertEqual(Vendoring.pins(inResolvedFileAt: root.appendingPathComponent("Package.resolved")), [:])
    }

    func test_eachCopyCarriesItsPin() throws {
        try write(".build/checkouts/GRDB.swift/Package.swift")
        try write(".build/checkouts/Unpinned/Package.swift")
        let grdb = Vendoring.Pin(origin: "https://github.com/groue/GRDB.swift.git", version: "7.11.1", revision: "b831")

        let copied = try Vendoring.copyCheckouts(from: checkouts, into: dependencies, pins: ["GRDB.swift": grdb])

        XCTAssertEqual(copied.map(\.pin), [grdb, nil])
    }

    /// The lock is beside the copy, not in it: in it, it would be a child the root folds.
    func test_theLockIsWrittenBesideTheCopyWithItsRoot() throws {
        try write(".build/checkouts/Nuke/Package.swift", "// nuke\n")
        let copied = try Vendoring.copyCheckouts(from: checkouts, into: dependencies)

        let lockFile = try Vendoring.writeLock(for: try XCTUnwrap(copied.first))

        XCTAssertEqual(lockFile.path, dependencies.appendingPathComponent("Nuke.semel-lock").path)
        let lock = try DependencyLock.parse(try String(contentsOf: lockFile, encoding: .utf8))
        XCTAssertEqual(lock.contentRoot, try FolderContentRoot.root(ofFolderAt: dependencies.appendingPathComponent("Nuke")))
        XCTAssertNil(lock.version)
        XCTAssertFalse(exists("Dependencies/Nuke/Nuke.semel-lock"))
    }

    func test_saysWhenNothingWasResolved() {
        XCTAssertThrowsError(try Vendoring.copyCheckouts(from: checkouts, into: dependencies)) { error in
            XCTAssertTrue(String(describing: error).contains("swift package resolve"), "got \(error)")
        }
    }
}
