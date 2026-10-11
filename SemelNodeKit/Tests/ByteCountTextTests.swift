//
//  ByteCountTextTests.swift
//  SemelNodeKitTests
//
//  A size as a person writes one, read and written. The prompt reads it and the home's
//  engine settings file reads and writes it, so what one writes the other reads back.
//

import SemelNodeKit
import XCTest

final class ByteCountTextTests: XCTestCase {

    func test_theExactTextNamesTheLargestUnitThatDividesTheSize() {
        XCTAssertEqual(ByteCount.gibibytes(10).exactText, "10G")
        XCTAssertEqual(ByteCount(bytes: 1_536 * ByteCount.mebibyte).exactText, "1536M")
        XCTAssertEqual(ByteCount(bytes: 8 * ByteCount.kibibyte).exactText, "8K")
        XCTAssertEqual(ByteCount(bytes: 4_097).exactText, "4097")
        XCTAssertEqual(ByteCount(bytes: 0).exactText, "0")
    }

    func test_theExactTextReadsBackAsTheSameBytes() {
        for bytes in [0, 1, 1_023, 1_024, 1_610_612_736, 3 * ByteCount.mebibyte + 1, ByteCount.gibibyte * 40] {
            XCTAssertEqual(ByteCount(parsing: ByteCount(bytes: bytes).exactText), ByteCount(bytes: bytes), "\(bytes)")
        }
    }

    func test_whatIsNotASizeIsRefused() {
        for refused in ["", "G", "20X", "-1", "1e3", "twenty", "1 G"] {
            XCTAssertNil(ByteCount(parsing: refused), refused)
        }
    }
}
