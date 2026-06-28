//
//  NodeSupportTests.swift
//  build_system_tests
//

import XCTest

final class NodeSupportTests: XCTestCase {

    // MARK: - lastPathComponent

    func test_lastPathComponent_singleSegment() {
        XCTAssertEqual("hello.c".lastPathComponent, "hello.c")
    }

    func test_lastPathComponent_twoSegments() {
        XCTAssertEqual("src/hello.c".lastPathComponent, "hello.c")
    }

    func test_lastPathComponent_deepPath() {
        XCTAssertEqual("a/b/c/d.h".lastPathComponent, "d.h")
    }

    func test_lastPathComponent_emptyString() {
        XCTAssertEqual("".lastPathComponent, "")
    }

    func test_lastPathComponent_trailingSlashIgnored() {
        // "a/b/" split by "/" omittingEmpty → ["a", "b"] → last = "b"
        XCTAssertEqual("a/b/".lastPathComponent, "b")
    }

    // MARK: - deletingLastPathComponent

    func test_deletingLastPathComponent_twoSegments() {
        XCTAssertEqual("src/hello.c".deletingLastPathComponent(), "src")
    }

    func test_deletingLastPathComponent_threeSegments() {
        XCTAssertEqual("a/b/c.h".deletingLastPathComponent(), "a/b")
    }

    func test_deletingLastPathComponent_singleSegment_returnsNil() {
        XCTAssertNil("hello.c".deletingLastPathComponent())
    }

    func test_deletingLastPathComponent_emptyString_returnsNil() {
        XCTAssertNil("".deletingLastPathComponent())
    }

    // MARK: - appendingPathComponent

    func test_appendingPathComponent_nonEmptyBase() {
        XCTAssertEqual("src".appendingPathComponent("hello.c"), "src/hello.c")
    }

    func test_appendingPathComponent_emptyBase() {
        XCTAssertEqual("".appendingPathComponent("hello.c"), "hello.c")
    }

    func test_appendingPathComponent_baseWithTrailingSlash() {
        XCTAssertEqual("src/".appendingPathComponent("hello.c"), "src/hello.c")
    }

    func test_appendingPathComponent_chained() {
        XCTAssertEqual("a".appendingPathComponent("b").appendingPathComponent("c.h"), "a/b/c.h")
    }

    func test_appendingPathComponent_deepBase() {
        XCTAssertEqual("usr/local/include".appendingPathComponent("stdio.h"), "usr/local/include/stdio.h")
    }

    // MARK: - removingSuffix

    func test_removingSuffix_matchingSuffix() {
        XCTAssertEqual("hello.c.pc".removingSuffix(".pc"), "hello.c")
    }

    func test_removingSuffix_noMatch_returnsOriginal() {
        XCTAssertEqual("hello.c".removingSuffix(".pc"), "hello.c")
    }

    func test_removingSuffix_emptyInput() {
        XCTAssertEqual("".removingSuffix(".pc"), "")
    }

    func test_removingSuffix_entireString() {
        XCTAssertEqual(".pc".removingSuffix(".pc"), "")
    }

    func test_removingSuffix_emptySuffix() {
        XCTAssertEqual("hello.c".removingSuffix(""), "hello.c")
    }

    func test_removingSuffix_doesNotRemovePrefix() {
        XCTAssertEqual("hello.c".removingSuffix("hello"), "hello.c")
    }

    // MARK: - Interaction between helpers

    func test_roundTrip_appendThenDelete() {
        let base = "src/include"
        let component = "stdio.h"
        let full = base.appendingPathComponent(component)
        XCTAssertEqual(full.deletingLastPathComponent(), base)
        XCTAssertEqual(full.lastPathComponent, component)
    }
}
