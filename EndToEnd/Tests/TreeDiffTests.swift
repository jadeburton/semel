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

    func test_exemptMatchesAnExactPathOrASuffix() {
        let difference = TreeDiff.Difference(path: "lib/libHelloKit.a", kind: .content(firstDifferingOffset: 33))

        XCTAssertTrue(EndToEndRun.exempt(difference, by: ["lib/libHelloKit.a"]), "an exact path match is exempt")
        XCTAssertTrue(EndToEndRun.exempt(difference, by: [".a"]), "a suffix match is exempt")
        XCTAssertFalse(EndToEndRun.exempt(difference, by: [".dylib"]), "no match is not exempt")
    }
}
