// CacheServerConfigurationTests.swift
// SemelCacheServerTests
//
// `semel.cache.config`: what `serve` writes reads back as the same settings, a hand edit
// that says something else is refused naming its line, and the command line is typed where
// it is typed.

import Foundation
import SemelCache
import SemelCacheServer
import SemelNodeKit
import SemelProtocol
import XCTest

final class CacheServerConfigurationTests: CacheServerTestCase {

    // MARK: - The file

    func test_whatIsWrittenReadsBackAsTheSameSettings() throws {
        let configuration = CacheServerConfiguration(listen: CacheAddress(host: "0.0.0.0", port: 7070),
                                                     limit: ByteCount(bytes: 1_536 * ByteCount.mebibyte),
                                                     writers: .all)

        try configuration.write(to: home.configurationFile)

        XCTAssertEqual(try CacheServerConfiguration.read(from: home.configurationFile), configuration)
        let text = try String(contentsOf: home.configurationFile, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# "), "the file says what it is")
        XCTAssertTrue(text.contains("limit    1536M\n"), "a size is written exactly: \(text)")
        XCTAssertTrue(text.contains("listen   0.0.0.0:7070\n"), text)
        XCTAssertTrue(text.contains("writers  all\n"), text)
    }

    func test_noFileIsNoSettings() throws {
        XCTAssertEqual(try CacheServerConfiguration.read(from: home.configurationFile), CacheServerConfiguration())
    }

    func test_aSettingTheFileDoesNotHaveIsRefusedNamingItsLine() {
        XCTAssertThrowsError(try CacheServerConfiguration.parse("# heading\nlisten 127.0.0.1:1\nspeed fast\n")) { error in
            XCTAssertEqual(error as? CacheServerConfigurationError, .unknownKey("speed", line: 3))
        }
        XCTAssertThrowsError(try CacheServerConfiguration.parse("limit 1G\nlimit 2G\n")) { error in
            XCTAssertEqual(error as? CacheServerConfigurationError, .repeatedKey("limit", line: 2))
        }
        XCTAssertThrowsError(try CacheServerConfiguration.parse("writers some\n")) { error in
            XCTAssertEqual(error as? CacheServerConfigurationError, .notWriters("some", line: 1))
        }
        XCTAssertThrowsError(try CacheServerConfiguration.parse("listen nowhere\n")) { error in
            XCTAssertEqual(error as? CacheServerConfigurationError, .notAnAddress("nowhere", line: 1))
        }
        XCTAssertThrowsError(try CacheServerConfiguration.parse("limit 20X\n")) { error in
            XCTAssertEqual(error as? CacheServerConfigurationError, .notASize("20X", line: 1))
        }
    }

    /// `serve`'s arguments go over the file, setting by setting, and what neither names
    /// stays unset.
    func test_theArgumentsGoOverTheFileSettingBySetting() {
        let file = CacheServerConfiguration(listen: CacheAddress(host: "127.0.0.1", port: 1), limit: ByteCount.gibibytes(5))
        let arguments = CacheServerConfiguration(writers: .all)

        XCTAssertEqual(file.overridden(by: arguments),
                       CacheServerConfiguration(listen: CacheAddress(host: "127.0.0.1", port: 1),
                                                limit: ByteCount.gibibytes(5), writers: .all))
    }

    func test_anAddressIsAHostAndAPort() {
        XCTAssertEqual(CacheAddress(parsing: "127.0.0.1:7070"), CacheAddress(host: "127.0.0.1", port: 7070))
        XCTAssertEqual(CacheAddress(parsing: "[::1]:7070"), CacheAddress(host: "::1", port: 7070))
        XCTAssertEqual(CacheAddress(host: "::1", port: 7070).description, "[::1]:7070")
        XCTAssertEqual(CacheAddress(parsing: "cache.lan:80")?.host, "cache.lan")
        XCTAssertNil(CacheAddress(parsing: "7070"))
        XCTAssertNil(CacheAddress(parsing: "host:70000"))
        XCTAssertNil(CacheAddress(parsing: ":7070"))
        XCTAssertEqual(CacheAddress(host: "0.0.0.0", port: 1).localHost, "127.0.0.1")
    }

    // MARK: - The command line

    func test_serveReadsEachArgumentAsTheValueItNames() throws {
        let command = try CacheCommand.parse(["serve", "--home", "/srv/cache", "--listen", "0.0.0.0:7070",
                                              "--limit", "20G", "--writers", "all"])

        XCTAssertEqual(command, .serve(home: CacheHome(folder: URL(fileURLWithPath: "/srv/cache", isDirectory: true)),
                                       settings: CacheServerConfiguration(listen: CacheAddress(host: "0.0.0.0", port: 7070),
                                                                          limit: ByteCount.gibibytes(20),
                                                                          writers: .all)))
    }

    func test_purgeTakesAKeyOrAll() throws {
        let key = String(repeating: "c", count: 64)
        let home = CacheHome(folder: URL(fileURLWithPath: "/srv/cache", isDirectory: true))

        XCTAssertEqual(try CacheCommand.parse(["purge", "--home", "/srv/cache", key]),
                       .purge(home: home, target: .key(CacheKey(hash: key))))
        XCTAssertEqual(try CacheCommand.parse(["purge", "--all", "--home", "/srv/cache"]), .purge(home: home, target: .all))
        XCTAssertThrowsError(try CacheCommand.parse(["purge", "--home", "/srv/cache", "abc"])) { error in
            XCTAssertEqual(error as? CacheCommandError, .notAKey("abc"))
        }
        XCTAssertThrowsError(try CacheCommand.parse(["purge", "--home", "/srv/cache"])) { error in
            XCTAssertEqual(error as? CacheCommandError, .purgeNeedsOneTarget)
        }
    }

    func test_aCommandWithoutAHomeOrWithAWrongValueIsRefusedByName() {
        XCTAssertThrowsError(try CacheCommand.parse(["status"])) { error in
            XCTAssertEqual(error as? CacheCommandError, .noHome)
        }
        XCTAssertThrowsError(try CacheCommand.parse(["serve", "--home", "/srv/cache", "--writers", "some"])) { error in
            XCTAssertEqual(error as? CacheCommandError, .notWriters("some"))
        }
        XCTAssertThrowsError(try CacheCommand.parse(["serve", "--home", "/srv/cache", "--limit"])) { error in
            XCTAssertEqual(error as? CacheCommandError, .missingValue("--limit"))
        }
        XCTAssertThrowsError(try CacheCommand.parse(["clean", "--home", "/srv/cache"])) { error in
            XCTAssertEqual(error as? CacheCommandError, .unknownVerb("clean"))
        }
    }
}
