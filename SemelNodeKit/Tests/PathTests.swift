//
//  PathTests.swift
//  build_system_tests
//

@testable import SemelNodeKit
import XCTest

final class PathTests: XCTestCase {

    // XCTestCase rather than the engine's SemelCoreTestCase: Path is a pure value type
    // with no process-globals to isolate, and SemelNodeKit deliberately cannot see the
    // engine's test helpers.

    // MARK: - init(_ string:)

    func testInitFromString_simple() {
        let p = Path("a/b/c")
        XCTAssertEqual(p.segments, ["a", "b", "c"])
    }

    func testInitFromString_leadingSlash() {
        let p = Path("/a/b")
        XCTAssertEqual(p.segments, ["a", "b"])
    }

    func testInitFromString_trailingSlash() {
        let p = Path("a/b/")
        XCTAssertEqual(p.segments, ["a", "b"])
    }

    func testInitFromString_doubleSlash() {
        let p = Path("a//b")
        XCTAssertEqual(p.segments, ["a", "b"])
    }

    func testInitFromString_empty() {
        let p = Path("")
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.segments, [])
    }

    func testInitFromString_singleSegment() {
        let p = Path("hello.c")
        XCTAssertEqual(p.segments, ["hello.c"])
    }

    // MARK: - Constants

    func testEmpty() {
        XCTAssertTrue(Path.empty.isEmpty)
        XCTAssertEqual(Path.empty.segments, [])
    }

    // MARK: - Properties

    func testIsEmpty_true() {
        XCTAssertTrue(Path("").isEmpty)
    }

    func testIsEmpty_false() {
        XCTAssertFalse(Path("a").isEmpty)
    }

    func testCount() {
        XCTAssertEqual(Path("a/b/c").count, 3)
        XCTAssertEqual(Path("").count, 0)
        XCTAssertEqual(Path("a").count, 1)
    }

    func testLastComponent_multiSegment() {
        XCTAssertEqual(Path("input:/src/hello.c").lastComponent, "hello.c")
    }

    func testLastComponent_singleSegment() {
        XCTAssertEqual(Path("hello.c").lastComponent, "hello.c")
    }

    func testLastComponent_empty() {
        XCTAssertNil(Path("").lastComponent)
    }

    func testFirstComponent_multiSegment() {
        XCTAssertEqual(Path("input:/src/hello.c").firstComponent, "input:")
    }

    func testFirstComponent_singleSegment() {
        XCTAssertEqual(Path("hello.c").firstComponent, "hello.c")
    }

    func testFirstComponent_empty() {
        XCTAssertNil(Path("").firstComponent)
    }

    // MARK: - deletingLastComponent

    func testDeletingLastComponent_multiSegment() {
        XCTAssertEqual(Path("a/b/c").deletingLastComponent, Path("a/b"))
    }

    func testDeletingLastComponent_twoSegments() {
        XCTAssertEqual(Path("a/b").deletingLastComponent, Path("a"))
    }

    func testDeletingLastComponent_singleSegment() {
        XCTAssertNil(Path("a").deletingLastComponent)
    }

    func testDeletingLastComponent_empty() {
        XCTAssertNil(Path("").deletingLastComponent)
    }

    // MARK: - deletingFirstComponent

    func testDeletingFirstComponent_multiSegment() {
        XCTAssertEqual(Path("input:/src/hello.c").deletingFirstComponent, Path("src/hello.c"))
    }

    func testDeletingFirstComponent_twoSegments() {
        XCTAssertEqual(Path("a/b").deletingFirstComponent, Path("b"))
    }

    func testDeletingFirstComponent_singleSegment() {
        XCTAssertNil(Path("a").deletingFirstComponent)
    }

    func testDeletingFirstComponent_empty() {
        XCTAssertNil(Path("").deletingFirstComponent)
    }

    // MARK: - containsWildcard

    func testContainsWildcard_star() {
        XCTAssertTrue(Path("src/*.c").containsWildcard)
    }

    func testContainsWildcard_questionMark() {
        XCTAssertTrue(Path("src/?.c").containsWildcard)
    }

    func testContainsWildcard_doubleStarSegment() {
        XCTAssertTrue(Path("src/**").containsWildcard)
    }

    func testContainsWildcard_none() {
        XCTAssertFalse(Path("src/hello.c").containsWildcard)
    }

    func testContainsWildcard_empty() {
        XCTAssertFalse(Path("").containsWildcard)
    }

    // MARK: - string

    func testString_multiSegment() {
        XCTAssertEqual(Path("a/b/c").string, "a/b/c")
    }

    func testString_singleSegment() {
        XCTAssertEqual(Path("hello.c").string, "hello.c")
    }

    func testString_empty() {
        XCTAssertEqual(Path("").string, "")
    }

    func testStringRoundTrip() {
        let original = "input:/src/hello.c"
        XCTAssertEqual(Path(original).string, original)
    }

    // MARK: - appending

    func testAppendingComponent() {
        XCTAssertEqual(Path("a/b").appending("c"), Path("a/b/c"))
    }

    func testAppendingPath() {
        XCTAssertEqual(Path("a/b").appending(Path("c/d")), Path("a/b/c/d"))
    }

    func testAppendingToEmpty() {
        XCTAssertEqual(Path("").appending("a"), Path("a"))
    }

    func testAppendingEmptyComponent() {
        // Empty component is filtered out — path is unchanged
        XCTAssertEqual(Path("a/b").appending(""), Path("a/b"))
    }

    // MARK: - / operator

    func testSlashOperator_string() {
        XCTAssertEqual(Path("a/b") / "c", Path("a/b/c"))
    }

    func testSlashOperator_path() {
        XCTAssertEqual(Path("a") / Path("b/c"), Path("a/b/c"))
    }

    func testSlashOperator_chain() {
        let p = Path("input:") / "src" / "hello.c"
        XCTAssertEqual(p, Path("input:/src/hello.c"))
    }

    // MARK: - hasPrefix

    func testHasPrefix_true() {
        XCTAssertTrue(Path("a/b/c").hasPrefix(Path("a/b")))
    }

    func testHasPrefix_fullMatch() {
        XCTAssertTrue(Path("a/b").hasPrefix(Path("a/b")))
    }

    func testHasPrefix_emptyPrefix() {
        XCTAssertTrue(Path("a/b").hasPrefix(Path("")))
    }

    func testHasPrefix_false() {
        XCTAssertFalse(Path("a/b/c").hasPrefix(Path("a/c")))
    }

    func testHasPrefix_longerPrefix() {
        XCTAssertFalse(Path("a/b").hasPrefix(Path("a/b/c")))
    }

    func testHasPrefix_partialSegmentNotMatched() {
        // "inputFileSystem2" must not match prefix "input:"
        XCTAssertFalse(Path("inputFileSystem2/src").hasPrefix(Path("input:")))
    }

    // MARK: - relative(to:)

    func testRelativeTo_normal() {
        let p = Path("input:/src/hello.c").relative(to: Path("input:"))
        XCTAssertEqual(p, Path("src/hello.c"))
    }

    func testRelativeTo_multipleSegmentsStripped() {
        let p = Path("a/b/c/d").relative(to: Path("a/b"))
        XCTAssertEqual(p, Path("c/d"))
    }

    func testRelativeTo_fullMatch() {
        let p = Path("a/b").relative(to: Path("a/b"))
        XCTAssertEqual(p, Path.empty)
    }

    func testRelativeTo_noPrefix() {
        XCTAssertNil(Path("a/b/c").relative(to: Path("x/y")))
    }

    func testRelativeTo_emptyBase() {
        XCTAssertEqual(Path("a/b").relative(to: Path("")), Path("a/b"))
    }

    // MARK: - subscript

    func testSubscript() {
        let p = Path("input:/src/hello.c")
        XCTAssertEqual(p[0], "input:")
        XCTAssertEqual(p[1], "src")
        XCTAssertEqual(p[2], "hello.c")
    }

    // MARK: - Equatable

    func testEquality_equal() {
        XCTAssertEqual(Path("a/b/c"), Path("a/b/c"))
    }

    func testEquality_notEqual() {
        XCTAssertNotEqual(Path("a/b"), Path("a/c"))
    }

    func testEquality_emptyPaths() {
        XCTAssertEqual(Path(""), Path.empty)
    }

    // MARK: - Hashable

    func testHashable_sameHashForEqualPaths() {
        let p1 = Path("a/b/c")
        let p2 = Path("a/b/c")
        XCTAssertEqual(p1.hashValue, p2.hashValue)
    }

    func testHashable_usableInSet() {
        let paths: Set<Path> = [Path("a/b"), Path("a/c"), Path("a/b")]
        XCTAssertEqual(paths.count, 2)
    }

    func testHashable_usableAsDictionaryKey() {
        var dict: [Path: String] = [:]
        dict[Path("a/b")] = "hello"
        XCTAssertEqual(dict[Path("a/b")], "hello")
    }

    // MARK: - ExpressibleByStringLiteral

    func testStringLiteralInit() {
        let p: Path = "src/hello.c"
        XCTAssertEqual(p, Path("src/hello.c"))
    }

    // MARK: - CustomStringConvertible

    func testDescription() {
        XCTAssertEqual(Path("a/b/c").description, "a/b/c")
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = Path("input:/src/hello.c")
        let data     = try JSONEncoder().encode(original)
        let decoded  = try JSONDecoder().decode(Path.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - String bridge

    func testAsPath() {
        XCTAssertEqual("src/hello.c".asPath, Path("src/hello.c"))
    }

    func testAsString() {
        XCTAssertEqual(Path("src/hello.c").asString, "src/hello.c")
    }
}
