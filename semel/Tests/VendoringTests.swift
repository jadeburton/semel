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

    /// The manifest reader for copies whose packages declare no binary target.
    private let noBinaryTargets: Vendoring.ReadManifestFacts = { _ in Vendoring.ManifestFacts() }

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

        let copied = try Vendoring.copyCheckouts(from: checkouts, into: dependencies, manifestFacts: noBinaryTargets)

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

        _ = try Vendoring.copyCheckouts(from: checkouts, into: dependencies, manifestFacts: noBinaryTargets)

        XCTAssertTrue(exists("Dependencies/Nuke/Package.swift"))
        XCTAssertFalse(exists("Dependencies/Nuke/.git"))
        XCTAssertFalse(exists("Dependencies/Nuke/.build"))
    }

    /// Running it again after a dependency changed must not leave stale files from the
    /// previous copy behind: the destination is replaced, not merged.
    func test_replacesAPreviousCopyRatherThanMergingIntoIt() throws {
        try write("Dependencies/Nuke/Sources/Old.swift")
        try write(".build/checkouts/Nuke/Sources/New.swift")

        _ = try Vendoring.copyCheckouts(from: checkouts, into: dependencies, manifestFacts: noBinaryTargets)

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

        let fromA = try Vendoring.copyCheckouts(from: root.appendingPathComponent("A/.build/checkouts"), into: shared, manifestFacts: noBinaryTargets)
        let fromB = try Vendoring.copyCheckouts(from: root.appendingPathComponent("B/.build/checkouts"), into: shared, manifestFacts: noBinaryTargets)

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

        let copied = try Vendoring.copyCheckouts(from: checkouts, into: dependencies, pins: ["GRDB.swift": grdb], manifestFacts: noBinaryTargets)

        XCTAssertEqual(copied.map(\.pin), [grdb, nil])
    }

    /// The lock is beside the copy, not in it: in it, it would be a child the root folds.
    func test_theLockIsWrittenBesideTheCopyWithItsRoot() throws {
        try write(".build/checkouts/Nuke/Package.swift", "// nuke\n")
        let copied = try Vendoring.copyCheckouts(from: checkouts, into: dependencies, manifestFacts: noBinaryTargets)

        let lockFile = try Vendoring.writeLock(for: try XCTUnwrap(copied.first))

        XCTAssertEqual(lockFile.path, dependencies.appendingPathComponent("Nuke.semel-lock").path)
        let lock = try DependencyLock.parse(try String(contentsOf: lockFile, encoding: .utf8))
        XCTAssertEqual(lock.contentRoot, try FolderContentRoot.root(ofFolderAt: dependencies.appendingPathComponent("Nuke")))
        XCTAssertNil(lock.version)
        XCTAssertFalse(exists("Dependencies/Nuke/Nuke.semel-lock"))
    }

    // MARK: - Only what moved (B-138)

    private let nuke = Vendoring.Pin(origin: "https://github.com/kean/Nuke.git", version: "12.0.0", revision: "aaaaaaa1")
    private let grdb = Vendoring.Pin(origin: "https://github.com/groue/GRDB.swift.git", version: "6.29.3", revision: "bbbbbbb1")

    /// Vendors and locks every checkout, as `prepare` does on its first run.
    @discardableResult
    private func vendorAndLock(pins: [String: Vendoring.Pin]) throws -> [Vendoring.Copied] {
        let copied = try Vendoring.copyCheckouts(from: checkouts, into: dependencies, pins: pins, manifestFacts: noBinaryTargets)
        for entry in copied where entry.change != .unchanged {
            try Vendoring.writeLock(for: entry)
        }
        return copied
    }

    private func lockText(_ name: String) throws -> Data {
        try Data(contentsOf: dependencies.appendingPathComponent("\(name).semel-lock"))
    }

    private func lock(_ name: String) throws -> DependencyLock {
        try DependencyLock.parse(String(decoding: try lockText(name), as: UTF8.self))
    }

    /// Every file under a copy with its bytes and its modification date: a copy made again
    /// has the same bytes and new dates, so equal snapshots mean the copy was not touched.
    private func snapshot(_ name: String) throws -> [String: String] {
        let folder = dependencies.appendingPathComponent(name, isDirectory: true)
        var entries: [String: String] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: folder.path))
        for case let relativePath as String in enumerator {
            let file = folder.appendingPathComponent(relativePath)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let date = try XCTUnwrap(attributes[.modificationDate] as? Date)
            let bytes = (try? Data(contentsOf: file)).map { $0.base64EncodedString() } ?? "folder"
            entries[relativePath] = "\(bytes) \(date.timeIntervalSinceReferenceDate)"
        }
        return entries
    }

    func test_anUnchangedPinLeavesTheCopyAndItsLockUntouched() throws {
        try write(".build/checkouts/Nuke/Package.swift", "// nuke\n")
        try write(".build/checkouts/Nuke/Sources/Nuke/Nuke.swift", "struct Nuke {}\n")
        try vendorAndLock(pins: ["Nuke": nuke])
        let lockBefore = try lockText("Nuke")
        let copyBefore = try snapshot("Nuke")
        Thread.sleep(forTimeInterval: 0.01)

        let copied = try vendorAndLock(pins: ["Nuke": nuke])

        XCTAssertEqual(copied.map(\.change), [.unchanged])
        XCTAssertEqual(try lockText("Nuke"), lockBefore)
        XCTAssertEqual(try snapshot("Nuke"), copyBefore)
    }

    func test_aMovedPinReVendorsThatCopyOnly() throws {
        try write(".build/checkouts/GRDB.swift/Package.swift", "// 6.29.3\n")
        try write(".build/checkouts/Nuke/Package.swift", "// nuke\n")
        try vendorAndLock(pins: ["GRDB.swift": grdb, "Nuke": nuke])
        let lockedBefore = try lock("GRDB.swift")
        let nukeBefore = try snapshot("Nuke")
        try write(".build/checkouts/GRDB.swift/Package.swift", "// 7.0.0\n")
        let moved = Vendoring.Pin(origin: grdb.origin, version: "7.0.0", revision: "ccccccc1")

        let copied = try vendorAndLock(pins: ["GRDB.swift": moved, "Nuke": nuke])

        XCTAssertEqual(copied.map(\.change), [.copied(.pinMoved(lockedBefore)), .unchanged])
        XCTAssertEqual(try String(contentsOf: dependencies.appendingPathComponent("GRDB.swift/Package.swift"), encoding: .utf8),
                       "// 7.0.0\n")
        XCTAssertEqual(try lock("GRDB.swift").version, "7.0.0")
        XCTAssertEqual(try snapshot("Nuke"), nukeBefore)
    }

    /// A revision that moves under its version is a tag moved, and an origin that moves is
    /// another repository: either is a pin that moved.
    func test_aMovedRevisionOrOriginIsAMovedPin() throws {
        try write(".build/checkouts/Nuke/Package.swift", "// nuke\n")
        try vendorAndLock(pins: ["Nuke": nuke])

        let retagged = Vendoring.Pin(origin: nuke.origin, version: nuke.version, revision: "ddddddd1")
        let lockedFirst = try lock("Nuke")
        XCTAssertEqual(try vendorAndLock(pins: ["Nuke": retagged]).map(\.change), [.copied(.pinMoved(lockedFirst))])

        let forked = Vendoring.Pin(origin: "https://example.com/fork/Nuke.git", version: nuke.version, revision: "ddddddd1")
        let lockedSecond = try lock("Nuke")
        XCTAssertEqual(try vendorAndLock(pins: ["Nuke": forked]).map(\.change), [.copied(.pinMoved(lockedSecond))])
    }

    func test_aCopyWithoutALockIsReVendored() throws {
        try write(".build/checkouts/Nuke/Package.swift", "// nuke\n")
        try vendorAndLock(pins: ["Nuke": nuke])
        try FileManager.default.removeItem(at: dependencies.appendingPathComponent("Nuke.semel-lock"))

        let copied = try vendorAndLock(pins: ["Nuke": nuke])

        XCTAssertEqual(copied.map(\.change), [.copied(.lockMissing)])
        XCTAssertEqual(try lock("Nuke").version, "12.0.0", "the copy is locked again")
    }

    func test_aLockThatDoesNotParseIsReVendored() throws {
        try write(".build/checkouts/Nuke/Package.swift", "// nuke\n")
        try vendorAndLock(pins: ["Nuke": nuke])
        try write("Dependencies/Nuke.semel-lock", "contents sha256:00\n")

        let copied = try vendorAndLock(pins: ["Nuke": nuke])

        XCTAssertEqual(copied.map(\.change), [.copied(.lockUnreadable(.unknownKey("contents", line: 1)))])
    }

    /// `prepare` is where a person asks for a copy to be made right: one changed by hand
    /// since its lock is copied again, whatever its pin says.
    func test_aCopyThatNoLongerFoldsToItsLockIsReVendored() throws {
        try write(".build/checkouts/Nuke/Package.swift", "// nuke\n")
        try vendorAndLock(pins: ["Nuke": nuke])
        let lockedBefore = try lock("Nuke")
        try write("Dependencies/Nuke/Package.swift", "// edited by hand\n")

        let copied = try vendorAndLock(pins: ["Nuke": nuke])

        XCTAssertEqual(copied.map(\.change), [.copied(.contentDiffers(lockedBefore))])
        XCTAssertEqual(try String(contentsOf: dependencies.appendingPathComponent("Nuke/Package.swift"), encoding: .utf8), "// nuke\n")
        XCTAssertEqual(try lock("Nuke"), lockedBefore, "the copy made again is the one the lock described")
    }

    func test_aLockTakenUnderAnotherFoldIsReVendored() throws {
        try write(".build/checkouts/Nuke/Package.swift", "// nuke\n")
        try vendorAndLock(pins: ["Nuke": nuke])
        var stale = try lock("Nuke")
        stale.fold = "content-root-0"
        try stale.text.write(to: dependencies.appendingPathComponent("Nuke.semel-lock"), atomically: true, encoding: .utf8)

        let copied = try vendorAndLock(pins: ["Nuke": nuke])

        XCTAssertEqual(copied.map(\.change), [.copied(.foldChanged(stale))])
    }

    /// The checksums are asked of the copy there, and only when its pin has not moved.
    func test_aLockWhoseChecksumsAreNotTheManifestsIsReVendored() throws {
        try write(".build/checkouts/Sparkle/Package.swift", "// sparkle\n")
        let sparkle = Vendoring.Pin(origin: "https://github.com/sparkle-project/Sparkle", version: "2.6.0", revision: "eeeeeee1")
        try vendorAndLock(pins: ["Sparkle": sparkle])
        var asked: [URL] = []

        let copied = try Vendoring.copyCheckouts(from: checkouts, into: dependencies, pins: ["Sparkle": sparkle],
                                                 manifestFacts: { copy in
                                                     asked.append(copy)
                                                     return Vendoring.ManifestFacts(artifacts: ["Sparkle": "4d5de3d3"])
                                                 })

        XCTAssertEqual(copied.map(\.change), [.copied(.artifactsDiffer(try lock("Sparkle")))])
        XCTAssertEqual(asked.map(\.lastPathComponent), ["Sparkle"])
    }

    /// B-143. A lock names the dot-named resources the copy's manifest declares and folds
    /// them into its root; a rerun whose manifest names the same leaves the copy, and one
    /// whose manifest names others copies it again.
    func test_aLockNamesTheDotNamedResourcesItsManifestDeclares() throws {
        try write(".build/checkouts/Kit/Package.swift", "// kit\n")
        try write(".build/checkouts/Kit/Sources/Kit/.config.json", "{}\n")
        let kit = Vendoring.Pin(origin: "https://example.com/Kit", version: "1.0.0", revision: "aaaaaaa1")
        let declared: Vendoring.ReadManifestFacts = { _ in Vendoring.ManifestFacts(hiddenFiles: ["Sources/Kit/.config.json"]) }
        let copied = try Vendoring.copyCheckouts(from: checkouts, into: dependencies, pins: ["Kit": kit], manifestFacts: declared)
        try Vendoring.writeLock(for: try XCTUnwrap(copied.first), facts: try declared(dependencies))

        let written = try lock("Kit")
        let copy = dependencies.appendingPathComponent("Kit")
        XCTAssertEqual(written.hiddenFiles, ["Sources/Kit/.config.json"])
        XCTAssertEqual(written.contentRoot, try FolderContentRoot.root(ofFolderAt: copy, hiddenFiles: written.hiddenFiles))
        XCTAssertNotEqual(written.contentRoot, try FolderContentRoot.root(ofFolderAt: copy))

        let again = try Vendoring.copyCheckouts(from: checkouts, into: dependencies, pins: ["Kit": kit], manifestFacts: declared)
        XCTAssertEqual(again.map(\.change), [.unchanged])
        let undeclared = try Vendoring.copyCheckouts(from: checkouts, into: dependencies, pins: ["Kit": kit],
                                                     manifestFacts: noBinaryTargets)
        XCTAssertEqual(undeclared.map(\.change), [.copied(.hiddenFilesDiffer(written))])
    }

    func test_aNewCheckoutIsVendoredAsAbsent() throws {
        try write(".build/checkouts/Nuke/Package.swift", "// nuke\n")

        XCTAssertEqual(try vendorAndLock(pins: ["Nuke": nuke]).map(\.change), [.copied(.absent)])
    }

    func test_saysWhenNothingWasResolved() {
        XCTAssertThrowsError(try Vendoring.copyCheckouts(from: checkouts, into: dependencies, manifestFacts: noBinaryTargets)) { error in
            XCTAssertTrue(String(describing: error).contains("swift package resolve"), "got \(error)")
        }
    }
}
