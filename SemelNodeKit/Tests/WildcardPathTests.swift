//
//  WildcardPathTests.swift
//  SemelNodeKitTests
//
//  A path below a folder against a pattern that may hold `**`: what a formula's
//  `<src/**/*.c>` matches, what a capture reads, and which folders a walk enters.
//

@testable import SemelNodeKit
import XCTest

final class WildcardPathTests: XCTestCase {

    private func segments(_ text: String) -> [String] {
        text.split(separator: "/").map(String.init)
    }

    private func matches(_ pattern: String, _ path: String) -> Bool {
        WildcardPath.matches(pattern: segments(pattern), path: segments(path))
    }

    private func reachesBelow(_ pattern: String, _ folder: String) -> Bool {
        WildcardPath.canMatchBelow(pattern: segments(pattern), folder: segments(folder))
    }

    // MARK: - Matching

    /// `**/` matches zero folders, so the folder the pattern starts in is included.
    func test_doubleStarMatchesZeroOrMoreFolders() {
        XCTAssertTrue(matches("**/*.c", "a.c"))
        XCTAssertTrue(matches("**/*.c", "lib/a.c"))
        XCTAssertTrue(matches("**/*.c", "lib/deep/a.c"))
        XCTAssertFalse(matches("**/*.c", "lib/a.h"))
    }

    /// A trailing `**` is every path below.
    func test_trailingDoubleStarMatchesEveryPathBelow() {
        XCTAssertTrue(matches("**", "a.c"))
        XCTAssertTrue(matches("**", "lib/deep/README"))
    }

    /// `*` stays inside one name, with or without a `**` elsewhere in the pattern.
    func test_singleStarDoesNotCrossAFolder() {
        XCTAssertTrue(matches("*.c", "a.c"))
        XCTAssertFalse(matches("*.c", "lib/a.c"))
        XCTAssertTrue(matches("*/a.c", "lib/a.c"))
        XCTAssertFalse(matches("*/a.c", "lib/deep/a.c"))
    }

    /// A `**` between literal folders stands for any folders between them, none included.
    func test_doubleStarBetweenLiteralFolders() {
        XCTAssertTrue(matches("lib/**/test/*.c", "lib/test/a.c"))
        XCTAssertTrue(matches("lib/**/test/*.c", "lib/x/y/test/a.c"))
        XCTAssertFalse(matches("lib/**/test/*.c", "lib/x/y/a.c"))
    }

    /// `**` inside a name is two `*`, not a path wildcard.
    func test_doubleStarInsideANameIsOneSegment() {
        XCTAssertTrue(matches("a**.c", "abc.c"))
        XCTAssertFalse(matches("a**.c", "a/b.c"))
    }

    // MARK: - Alignment

    /// What a capture reads: after a `**`, the next segment is the path's last, not the
    /// one at the same position.
    func test_alignmentGivesEachPatternSegmentTheSegmentsItMatched() {
        XCTAssertEqual(WildcardPath.alignment(pattern: segments("src/**/*.c"), path: segments("src/lib/deep/a.c")),
                       [0..<1, 1..<3, 3..<4])
        XCTAssertEqual(WildcardPath.alignment(pattern: segments("src/**/*.c"), path: segments("src/a.c")),
                       [0..<1, 1..<1, 1..<2])
        XCTAssertNil(WildcardPath.alignment(pattern: segments("src/**/*.c"), path: segments("lib/a.c")))
    }

    // MARK: - Which folders a walk enters

    func test_aOneNamePatternEntersNoFolder() {
        XCTAssertFalse(reachesBelow("*.c", "lib"))
        XCTAssertFalse(reachesBelow("*", "lib"))
    }

    func test_aDoubleStarPatternEntersEveryFolder() {
        XCTAssertTrue(reachesBelow("**/*.c", "lib"))
        XCTAssertTrue(reachesBelow("**/*.c", "lib/deep"))
        XCTAssertTrue(reachesBelow("**", "lib/deep"))
    }

    /// A pattern with folders in it enters only the folders those segments can match,
    /// and no deeper than they go.
    func test_aPatternWithFoldersEntersOnlyWhatItsSegmentsMatch() {
        XCTAssertTrue(reachesBelow("*/*.c", "lib"))
        XCTAssertFalse(reachesBelow("*/*.c", "lib/deep"))
        XCTAssertTrue(reachesBelow("lib/**/*.c", "lib/deep"))
        XCTAssertFalse(reachesBelow("lib/**/*.c", "tests"))
    }
}
