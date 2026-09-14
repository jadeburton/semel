//
//  SemelPathsTests.swift
//  SemelNodeKit
//

import Foundation
@testable import SemelNodeKit
import XCTest

/// The graph database and the object store refer to each other — a cache entry holds
/// object hashes — so they live under one absolute root, whatever directory semel was
/// launched from. The database used to be a bare filename relative to the launch
/// directory, which silently started an empty graph against the shared store.
final class SemelPathsTests: XCTestCase {

    func test_everythingPersistedLivesUnderOneAbsoluteRoot() {
        XCTAssertTrue(SemelPaths.root.path.hasPrefix("/"), "got \(SemelPaths.root.path)")
        XCTAssertEqual(SemelPaths.database.deletingLastPathComponent(), SemelPaths.root)
        XCTAssertEqual(SemelPaths.objectStore.deletingLastPathComponent(), SemelPaths.root)
    }

    func test_thePathsDoNotDependOnTheCurrentDirectory() throws {
        let before = SemelPaths.database.path
        let original = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(original) }

        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(NSTemporaryDirectory()))

        XCTAssertEqual(SemelPaths.database.path, before)
        XCTAssertFalse(before.hasPrefix(NSTemporaryDirectory()))
    }

    func test_theDefaultObjectStoreUsesTheSharedRoot() {
        XCTAssertEqual(SemelPaths.objectStore.lastPathComponent, "objects")
        XCTAssertEqual(SemelPaths.root.lastPathComponent, "semel")
    }

    // MARK: - Overrides

    /// A server under test must never open the user's graph, so the whole root moves with
    /// one variable; the socket has its own so a test can point at a server it did not
    /// start.
    func test_rootHonoursSemelHome() {
        setenv("SEMEL_HOME", "/tmp/semel-paths-test-home", 1)
        defer { unsetenv("SEMEL_HOME") }

        XCTAssertEqual(SemelPaths.root.path, "/tmp/semel-paths-test-home")
        XCTAssertEqual(SemelPaths.database.path, "/tmp/semel-paths-test-home/graph.sqlite")
        XCTAssertEqual(SemelPaths.serverSocket.path, "/tmp/semel-paths-test-home/semelserv.sock")
    }

    func test_serverSocketHonoursSemelSocket() {
        setenv("SEMEL_SOCKET", "/tmp/semel-paths-test.sock", 1)
        defer { unsetenv("SEMEL_SOCKET") }

        XCTAssertEqual(SemelPaths.serverSocket.path, "/tmp/semel-paths-test.sock")
    }

    func test_serverSocketDefaultsToTheRoot() {
        unsetenv("SEMEL_SOCKET")

        XCTAssertEqual(SemelPaths.serverSocket, SemelPaths.root.appendingPathComponent("semelserv.sock", isDirectory: false))
    }
}
