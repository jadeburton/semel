//
//  TreeDiffTests.swift
//  SemelEndToEndTests
//

import XCTest

final class TreeDiffTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("semel-treediff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func write(_ tree: String, _ path: String, _ bytes: [UInt8], mode: Int = 0o644) throws {
        let url = folder.appendingPathComponent(tree).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func test_identicalTreesHaveNoDifferences() throws {
        try write("a", "x/one", [1, 2, 3]); try write("b", "x/one", [1, 2, 3])

        XCTAssertEqual(try TreeDiff.compare(folder.appendingPathComponent("a"), folder.appendingPathComponent("b")).count, 0)
    }

    func test_namesEachKindOfDifferenceWithItsPath() throws {
        try write("a", "only-in-a", [1])
        try write("b", "only-in-b", [1])
        try write("a", "mode", [1], mode: 0o755); try write("b", "mode", [1], mode: 0o644)
        try write("a", "size", [1, 2]);            try write("b", "size", [1])
        try write("a", "sub/content", [9, 9, 9, 1]); try write("b", "sub/content", [9, 9, 9, 2])

        let differences = try TreeDiff.compare(folder.appendingPathComponent("a"), folder.appendingPathComponent("b"))

        XCTAssertEqual(differences.map(\.description), [
            "mode: mode 755 vs 644",
            "only-in-a: only in the first tree",
            "only-in-b: only in the second tree",
            "size: size 2 vs 1",
            "sub/content: content differs at offset 3",
        ])
    }

    /// B-77. A link is compared by what it holds, never followed; a link where the other
    /// tree has a file is a difference too.
    func test_aLinkIsComparedByItsTarget() throws {
        try write("a", "F/Versions/A/Tiny", [1]); try write("b", "F/Versions/A/Tiny", [1])
        try write("a", "F/Versions/B/Tiny", [1]); try write("b", "F/Versions/B/Tiny", [1])
        try write("b", "F/Tiny", [1])
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(atPath: folder.appendingPathComponent("a/F/Versions/Current").path, withDestinationPath: "A")
        try fileManager.createSymbolicLink(atPath: folder.appendingPathComponent("b/F/Versions/Current").path, withDestinationPath: "B")
        try fileManager.createSymbolicLink(atPath: folder.appendingPathComponent("a/F/Tiny").path, withDestinationPath: "Versions/Current/Tiny")

        let differences = try TreeDiff.compare(folder.appendingPathComponent("a"), folder.appendingPathComponent("b"))

        XCTAssertEqual(differences.map(\.description), [
            "F/Tiny: a link to Versions/Current/Tiny vs a file",
            "F/Versions/Current: a link to A vs a link to B",
        ])
    }

    func test_exemptMatchesAnExactPathOrATrailingPath() {
        let difference = TreeDiff.Difference(path: "lib/libHelloKit.a", kind: .content(firstDifferingOffset: 33))

        XCTAssertTrue(EndToEndRun.exempt(difference, by: ["lib/libHelloKit.a"]), "an exact path match is exempt")
        XCTAssertTrue(EndToEndRun.exempt(difference, by: ["libHelloKit.a"]), "a trailing path component is exempt")
        XCTAssertFalse(EndToEndRun.exempt(difference, by: [".a"]), "a bare character suffix is not a path component")
        XCTAssertFalse(EndToEndRun.exempt(difference, by: [".dylib"]), "no match is not exempt")
    }

    /// A component boundary is required: `Assets.car` must not exempt a file that merely
    /// ends with those characters inside a different, longer name.
    func test_exemptDoesNotMatchAcrossAPathComponentBoundary() {
        let difference = TreeDiff.Difference(path: "My Ice Cubes.app/Assets.car", kind: .content(firstDifferingOffset: 0))

        XCTAssertFalse(EndToEndRun.exempt(difference, by: ["Ice Cubes.app/Assets.car"]),
                       "the exemption names a different, shorter bundle name")
    }
}
