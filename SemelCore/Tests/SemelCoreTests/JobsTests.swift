//
//  JobsTests.swift
//  SemelCore
//
//  B-114. The concurrency limit is a setting: `SEMEL_JOBS`, or the core count.
//

@testable import SemelCore
import SemelNodeKit
import XCTest

final class JobsTests: XCTestCase {

    func test_unsetIsTheCoreCount() {
        let resolved = Jobs.resolve(environment: [:])

        XCTAssertEqual(resolved.count, MachineQuery.activeProcessorCount)
        XCTAssertNil(resolved.ignored)
    }

    func test_aPositiveIntegerIsTheLimit() {
        let resolved = Jobs.resolve(environment: ["SEMEL_JOBS": "3"])

        XCTAssertEqual(resolved.count, 3)
        XCTAssertNil(resolved.ignored)
    }

    /// A value that is not a positive integer falls back to the core count and is named,
    /// so the banner can say it was ignored rather than let it pass for a setting.
    func test_anythingElseIsIgnoredAndSaidSo() {
        for value in ["0", "-2", "eight", "2.5"] {
            let resolved = Jobs.resolve(environment: ["SEMEL_JOBS": value])

            XCTAssertEqual(resolved.count, MachineQuery.activeProcessorCount, value)
            XCTAssertEqual(resolved.ignored, value)
        }
    }

    func test_anEmptyValueIsUnset() {
        let resolved = Jobs.resolve(environment: ["SEMEL_JOBS": ""])

        XCTAssertEqual(resolved.count, MachineQuery.activeProcessorCount)
        XCTAssertNil(resolved.ignored)
    }
}
