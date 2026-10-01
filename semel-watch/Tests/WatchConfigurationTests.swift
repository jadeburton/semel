//
//  WatchConfigurationTests.swift
//  SemelWatchTests
//
//  B-126. `semel-watch <base> [<folder> ...]` and its flags, read as `build` reads its
//  folder: relative to the base.
//

import Foundation
import SemelNodeKit
@testable import SemelWatch
import XCTest

final class WatchConfigurationTests: XCTestCase {

    private var directory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let made = try makeTemporaryDirectory()
        directory = made
        for folder in ["tree/Packages", "tree/Docs"] {
            try FileManager.default.createDirectory(at: made.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let directory {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func test_theFoldersAreReadFromTheBaseAndTheDestinationFromTheCurrentDirectory() throws {
        let directory = try XCTUnwrap(self.directory)

        let configuration = try WatchConfiguration.parse(["tree", "Packages", "./Docs", "--into", "out",
                                                          "--only", "**/*.swift", "--only", "**/*.h",
                                                          "--except", "**/Tests/**", "--settle-after", "500",
                                                          "--no-initial"],
                                                         currentDirectory: directory.path)

        XCTAssertEqual(configuration.base, directory.appendingPathComponent("tree").path)
        XCTAssertEqual(configuration.folders, ["Packages", "Docs"])
        XCTAssertEqual(configuration.exportDestination, directory.appendingPathComponent("out").path)
        XCTAssertEqual(configuration.only, ["**/*.swift", "**/*.h"])
        XCTAssertEqual(configuration.except, ["**/Tests/**"])
        XCTAssertEqual(configuration.quietInterval, .milliseconds(500))
        XCTAssertFalse(configuration.pushesInitially)
        XCTAssertTrue(configuration.printsReports)
    }

    /// No folder is the base itself, `.` as `build` would be told it; two seconds of quiet.
    func test_noFolderIsTheBaseItself() throws {
        let directory = try XCTUnwrap(self.directory)

        let configuration = try WatchConfiguration.parse([directory.appendingPathComponent("tree").path],
                                                         currentDirectory: "/")

        XCTAssertEqual(configuration.folders, [.empty])
        XCTAssertEqual(configuration.quietInterval, .seconds(2))
        XCTAssertTrue(configuration.pushesInitially)
    }

    /// A destination under the base is excepted by the filter, by its path from the base.
    func test_aDestinationUnderTheBaseIsExcepted() throws {
        let directory = try XCTUnwrap(self.directory)

        let configuration = try WatchConfiguration.parse(["tree", "--into", "tree/out/app"], currentDirectory: directory.path)

        XCTAssertEqual(configuration.filter.alwaysExcepted, ["semel-out", "out/app"])
    }

    func test_whatCannotBeWatchedIsSaid() throws {
        let directory = try XCTUnwrap(self.directory).path

        XCTAssertThrowsError(try WatchConfiguration.parse([], currentDirectory: directory)) {
            XCTAssertEqual($0 as? WatchArgumentError, .missingBase)
        }
        XCTAssertThrowsError(try WatchConfiguration.parse(["tree", "Missing"], currentDirectory: directory)) {
            XCTAssertEqual($0 as? WatchArgumentError, .notAFolder("Missing"))
        }
        XCTAssertThrowsError(try WatchConfiguration.parse(["tree/Packages", "../Docs"], currentDirectory: directory)) {
            XCTAssertEqual($0 as? WatchArgumentError,
                           .outsideBase(folder: "../Docs", base: "\(directory)/tree/Packages"))
        }
        XCTAssertThrowsError(try WatchConfiguration.parse(["tree", "--settle-after", "soon"], currentDirectory: directory)) {
            XCTAssertEqual($0 as? WatchArgumentError, .notMilliseconds("soon"))
        }
        XCTAssertThrowsError(try WatchConfiguration.parse(["tree", "--follow"], currentDirectory: directory)) {
            XCTAssertEqual($0 as? WatchArgumentError, .unknownOption("--follow"))
        }
        XCTAssertThrowsError(try WatchConfiguration.parse(["tree", "--into"], currentDirectory: directory)) {
            XCTAssertEqual($0 as? WatchArgumentError, .missingValue(flag: "--into"))
        }
    }
}
