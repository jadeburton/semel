//
//  ExternalFileSystemListerTests.swift
//  SemelNodeKitTests
//

@testable import SemelNodeKit
import Foundation
import XCTest

/// The lister a push walks the disk with. A real package tree has symbolic links in it —
/// RevenueCat keeps a target's sources behind one, and a test fixture of its links back
/// to the package root — so following links is required and following a cycle is fatal:
/// the walk grows without end until memory runs out.
final class ExternalFileSystemListerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-lister-tests/\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("pkg/Sources"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("pkg/Tests/Deep"), withIntermediateDirectories: true)
        try "swift".write(to: root.appendingPathComponent("pkg/Sources/A.swift"), atomically: true, encoding: .utf8)
        // A link beside the sources, as RevenueCat's CustomEntitlementComputation is.
        try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("pkg/Alias").path, withDestinationPath: "Sources")
        // A link back to the package root, as its Carthage fixture is.
        try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("pkg/Tests/Deep/root").path, withDestinationPath: "../../")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func test_followsALinkBesideTheSourcesButNotOneBackUpTheTree() throws {
        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: root.path))

        let paths = try matcher.findAllMatching(pathOrWildcard: "pkg/**/*").map(\.path.string).sorted()

        XCTAssertTrue(paths.contains("pkg/Sources/A.swift"), "\(paths)")
        XCTAssertTrue(paths.contains("pkg/Alias/A.swift"), "a link to a sibling is a folder of its own: \(paths)")
        XCTAssertFalse(paths.contains { $0.contains("/root") }, "a link up the tree is a cycle, never entered: \(paths)")
    }

    // MARK: - Links pushed as links (B-77)

    /// A link that stays inside its own folder is listed with what it holds, and is still
    /// the file or folder it names — walked, so everything that read through it before
    /// reads through it still. A link that climbs out of its folder, or is absolute, is
    /// followed with nothing said about it, as every link was.
    func test_aLinkInsideItsFolderSaysWhatItHoldsAndIsStillWalked() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("fw/Tiny.framework/Versions/A/Headers"),
                                        withIntermediateDirectories: true)
        try "binary".write(to: root.appendingPathComponent("fw/Tiny.framework/Versions/A/Tiny"), atomically: true, encoding: .utf8)
        try "header".write(to: root.appendingPathComponent("fw/Tiny.framework/Versions/A/Headers/Tiny.h"),
                           atomically: true, encoding: .utf8)
        try "outside".write(to: root.appendingPathComponent("fw/outside.h"), atomically: true, encoding: .utf8)
        let framework = root.appendingPathComponent("fw/Tiny.framework")
        try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent("Tiny").path, withDestinationPath: "Versions/Current/Tiny")
        try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent("Headers").path, withDestinationPath: "Versions/Current/Headers")
        try fileManager.createSymbolicLink(atPath: framework.appendingPathComponent("Outside.h").path, withDestinationPath: "../outside.h")

        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: root.path))
        let entries = try matcher.findAllMatching(pathOrWildcard: "fw/Tiny.framework/**/*")
        let targets = Dictionary(entries.map { ($0.path.string, $0.symbolicLinkTarget ?? "-") }) { first, _ in first }

        XCTAssertEqual(targets["fw/Tiny.framework/Versions/Current"], "A")
        XCTAssertEqual(targets["fw/Tiny.framework/Tiny"], "Versions/Current/Tiny")
        XCTAssertEqual(targets["fw/Tiny.framework/Headers"], "Versions/Current/Headers")
        XCTAssertEqual(targets["fw/Tiny.framework/Outside.h"], "-", "a link out of its folder is followed as before")
        XCTAssertEqual(targets["fw/Tiny.framework/Versions/Current/Headers/Tiny.h"], "-", "what a folder link names is walked")
        XCTAssertEqual(targets["fw/Tiny.framework/Headers/Tiny.h"], "-")
        XCTAssertEqual(entries.first { $0.path.string == "fw/Tiny.framework/Headers" }?.kind, .folder)
        XCTAssertEqual(entries.first { $0.path.string == "fw/Tiny.framework/Tiny" }?.kind, .file)
    }

    // MARK: - A dot-named file named exactly (B-77 item 5)

    /// A path naming a dot-named file exactly finds it — what a formula's `StaticFile`
    /// names, and so what `push` and `build`'s follow of a missing source push — while a
    /// wildcard, `**` and a dot-named folder named exactly still find no dot-name.
    func test_aDotNamedFileIsFoundOnlyWhenItsPathNamesIt() throws {
        let fileManager = FileManager.default
        try "{}".write(to: root.appendingPathComponent("pkg/.all-contributorsrc"), atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: root.appendingPathComponent("pkg/.github/workflows"), withIntermediateDirectories: true)
        try "on: push".write(to: root.appendingPathComponent("pkg/.github/workflows/ci.yml"), atomically: true, encoding: .utf8)
        let matcher = FileWildcardMatcher(input: ExternalFileSystemLister(rootDirectoryPath: root.path))

        let named = try matcher.findAllMatching(pathOrWildcard: "pkg/.all-contributorsrc")
        XCTAssertEqual(named.map(\.path.string), ["pkg/.all-contributorsrc"])
        XCTAssertEqual(named.first?.kind, .file)

        for pattern in ["pkg/*", "pkg/.*", "pkg/**/*", "pkg/.all-contributors?c", "pkg/.github",
                        "pkg/.github/workflows/ci.yml", "pkg/.missing"] {
            let found = try matcher.findAllMatching(pathOrWildcard: pattern).map(\.path.string)
            XCTAssertFalse(found.contains { $0.split(separator: "/").contains { $0.hasPrefix(".") } }, "\(pattern): \(found)")
        }
    }

    /// Inside its own folder means a relative target that never climbs above that folder,
    /// names no dot-named component a push would leave out, and names something below it.
    func test_whichTargetsStayInsideTheirFolder() {
        for inside in ["A", "Versions/Current/Tiny", "./A", "B/../A", "Versions/Current/"] {
            XCTAssertTrue(ExternalFileSystemLister.isContained(symbolicLinkTarget: inside), inside)
        }
        for outside in ["/usr/lib", "../A", "A/../..", ".", "", "B/..", ".hidden/A", "A/.git"] {
            XCTAssertFalse(ExternalFileSystemLister.isContained(symbolicLinkTarget: outside), outside)
        }
    }
}
