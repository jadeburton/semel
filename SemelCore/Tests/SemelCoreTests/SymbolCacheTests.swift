//
//  SymbolCacheTests.swift
//  build_system_tests
//

@testable import SemelCore
import XCTest
import SemelNodeKit

/// `asSymbolID()` interns names in a process-global cache, but each `DatabaseLayer`
/// replaces `DatabaseLayer.shared`. Ids held over from a previous database refer to
/// Symbol rows that do not exist in the current one.
final class SymbolCacheTests: SemelCoreTestCase {

    func testSymbolIDResolvesInTheDatabaseThatIsCurrent() throws {
        _ = try DatabaseLayer()
        _ = try "symbol-cache-probe".asSymbolID()

        _ = try DatabaseLayer()
        let id = try "symbol-cache-probe".asSymbolID()

        XCTAssertNotNil(try DatabaseLayer.shared.symbol.select(symbolID: id),
                        "symbol id must name a row in the current database")
    }
}
