//
//  EngineConfigurationTests.swift
//  SemelServerTests
//
//  `semel.engine.config`: the engine's own settings in the home, read strictly and written
//  so they read back as they were.
//

import Foundation
import SemelNodeKit
@testable import SemelServer
import XCTest

final class EngineConfigurationTests: XCTestCase {

    private var home: URL!

    private var file: URL {
        home.appendingPathComponent(EngineConfiguration.fileName, isDirectory: false)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-engine-configuration-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        home = nil
        super.tearDown()
    }

    // MARK: - Reading and writing

    func test_aHomeWithNoFileSetsNothing() throws {
        XCTAssertEqual(try EngineConfiguration.read(from: file), EngineConfiguration())
    }

    func test_whatIsWrittenReadsBackAsItWas() throws {
        let configuration = EngineConfiguration(cacheLimit: ByteCount(bytes: 1_536 * ByteCount.mebibyte))

        try configuration.write(to: file)

        XCTAssertEqual(try EngineConfiguration.read(from: file), configuration)
    }

    func test_theFileIsAHeadingAndOneLinePerSettingSet() {
        let text = EngineConfiguration(cacheLimit: ByteCount.gibibytes(20)).text
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        XCTAssertTrue(lines.dropLast(2).allSatisfy { $0.hasPrefix("# ") }, text)
        XCTAssertEqual(lines.suffix(2), ["cache.limit  20G", ""])
        XCTAssertFalse(EngineConfiguration().text.split(separator: "\n").contains { $0.hasPrefix("cache.limit") },
                       "an unset setting has no line")
    }

    func test_commentsBlankLinesAndASizeWithAUnitAreRead() throws {
        let text = "# by hand\n\n   cache.limit\t 512m  \n"

        XCTAssertEqual(try EngineConfiguration.parse(text), EngineConfiguration(cacheLimit: ByteCount(bytes: 512 * ByteCount.mebibyte)))
    }

    // MARK: - Refusals

    func test_anUnknownKeyIsRefusedNamingItsLine() {
        XCTAssertThrowsError(try EngineConfiguration.parse("# heading\ncache.server  example:9000\n")) { error in
            XCTAssertEqual(error as? EngineConfigurationError, .unknownKey("cache.server", line: 2))
        }
    }

    func test_aKeySaidTwiceIsRefused() {
        XCTAssertThrowsError(try EngineConfiguration.parse("cache.limit 1G\ncache.limit 2G\n")) { error in
            XCTAssertEqual(error as? EngineConfigurationError, .repeatedKey("cache.limit", line: 2))
        }
    }

    func test_aKeyWithNoValueIsRefused() {
        XCTAssertThrowsError(try EngineConfiguration.parse("cache.limit\n")) { error in
            XCTAssertEqual(error as? EngineConfigurationError, .emptyValue("cache.limit", line: 1))
        }
    }

    func test_aLimitThatIsNotASizeIsRefused() {
        XCTAssertThrowsError(try EngineConfiguration.parse("cache.limit  twenty gigs\n")) { error in
            XCTAssertEqual(error as? EngineConfigurationError, .notASize("cache.limit", "twenty gigs", line: 1))
            XCTAssertEqual("\(error)", "line 1: 'twenty gigs' is not a size for 'cache.limit'; "
                                     + "give bytes, or a number with K, M or G after it")
        }
    }
}
