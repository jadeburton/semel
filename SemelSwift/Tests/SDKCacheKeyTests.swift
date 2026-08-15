//
//  SDKCacheKeyTests.swift
//  SemelSwiftTests
//
//  The SDK a node compiles against changes its output, but is resolved from the machine at
//  process time rather than arriving on a wire — so nothing put it in the cache key. Two
//  developers on different SDKs produced different object files under identical keys, which
//  is mild staleness locally and silent corruption once a cache is shared.
//
//  These moved here with their subjects: the assertion belongs to the toolchain that reads
//  the SDK, not to the engine that caches the result.
//

@testable import SemelSwift
import DatabaseModels
import SemelNodeKit
import XCTest

final class SDKCacheKeyTests: SemelSwiftTestCase {

    func test_theSwiftCompilerRecordsItsSDKInTheCacheKey() throws {
        let tool = try SwiftCompilerTool(thisNode: Node(id: 1, kind: SwiftCompilerTool.kind))

        XCTAssertFalse(tool.cacheKeyEnvironment.isEmpty,
                       "the SDK influences the output, so it must contribute to the key")
    }

    func test_theSwiftLinkerRecordsItsSDKInTheCacheKey() throws {
        let tool = try SwiftLinkerTool(thisNode: Node(id: 1, kind: SwiftLinkerTool.kind))

        XCTAssertFalse(tool.cacheKeyEnvironment.isEmpty,
                       "the SDK influences the output, so it must contribute to the key")
    }
}
