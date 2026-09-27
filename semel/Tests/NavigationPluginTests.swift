//
//  NavigationPluginTests.swift
//  SemelCLITests
//
//  ls, cd and pwd over a scripted connection. The rules that stay client-side — a single
//  matched folder is listed by its contents, a path is resolved against the current
//  directory before it is sent — are what these pin.
//

@testable import SemelCLI
import SemelNodeKit
import SemelProtocol
import XCTest

final class NavigationPluginTests: XCTestCase {

    private var connection: RecordingConnection!
    private var context: TestCommandContext!

    override func setUp() {
        super.setUp()
        connection = RecordingConnection()
        context    = TestCommandContext(connection: connection)
    }

    private func run(_ verb: String, _ tokens: [String] = []) throws {
        try NavigationPlugin().handle(verb: verb, tokens: tokens, context: context)
    }

    func test_pwdPrintsTheCurrentLocation() throws {
        context.currentDirectoryPath = Path("src")

        try run("pwd")

        XCTAssertEqual(context.messages, ["input:/src"])
    }

    func test_lsListsTheCurrentDirectoryWithModesAndSizes() throws {
        connection.reply(.list(entries: [
            ListEntry(path: "main.c", kind: .file,   size: 120, mode: 0o644, status: .none),
            ListEntry(path: "lib",    kind: .folder, size: nil, mode: nil,   status: .none),
        ]))

        try run("ls")

        XCTAssertEqual(connection.daemonRequests, [.list(fileSystem: .input, pattern: "*")])
        XCTAssertEqual(context.messages, [
            "d---------         -  lib/",
            "-rw-r--r--       120  main.c",
        ])
    }

    func test_lsOfASingleFolderListsItsContents() throws {
        connection.reply(.list(entries: [ListEntry(path: "src", kind: .folder, size: nil, mode: nil, status: .none)]))
        connection.reply(.list(entries: [ListEntry(path: "src/a.c", kind: .file, size: 1, mode: 0o644, status: .pending)]))

        try run("ls", ["src"])

        XCTAssertEqual(connection.daemonRequests, [
            .list(fileSystem: .input, pattern: "src"),
            .list(fileSystem: .input, pattern: "src/*"),
        ])
        XCTAssertEqual(context.messages, ["-rw-r--r--         1  a.c  [pending]"])
    }

    /// Every word `ls` prints beside a name, pinned. The states are not interchangeable —
    /// one settles by itself, one is a failure to act on, one is neither — and these words
    /// are the whole of what tells a reader which is which.
    func test_lsPrintsItsOwnWordForEachState() throws {
        connection.reply(.list(entries: [
            ListEntry(path: "built.o",    kind: .file, size: 4,   mode: 0o644, status: .none),
            ListEntry(path: "nobodys.o",  kind: .file, size: nil, mode: 0o644, status: .unreferenced),
            ListEntry(path: "waiting.o",  kind: .file, size: nil, mode: 0o644, status: .pending),
            ListEntry(path: "unpushed.o", kind: .file, size: nil, mode: 0o644, status: .notProduced),
            ListEntry(path: "removed.o",  kind: .file, size: nil, mode: 0o644, status: .deleted),
            ListEntry(path: "broken.o",   kind: .file, size: nil, mode: 0o644, status: .failed),
        ]))

        try run("ls")

        XCTAssertEqual(context.messages, [
            "-rw-r--r--         -  broken.o  [failed]",
            "-rw-r--r--         4  built.o",
            "-rw-r--r--         -  nobodys.o  [unreferenced]",
            "-rw-r--r--         -  removed.o  [deleted]",
            "-rw-r--r--         -  unpushed.o  [not pushed]",
            "-rw-r--r--         -  waiting.o  [pending]",
        ])
    }

    /// B-118. Nothing is produced in `input:`: there the state is a source nobody pushed.
    /// In `output:` it is a product whose input has no value, and the word says so.
    func test_aNameWithNoValueIsNotPushedInInputAndNotProducedInOutput() throws {
        connection.reply(.list(entries: [
            ListEntry(path: "semel.machine.config", kind: .file, size: nil, mode: 0o644, status: .notProduced),
        ]))
        try run("ls")
        connection.reply(.list(entries: [
            ListEntry(path: "hello", kind: .file, size: nil, mode: 0o644, status: .notProduced),
        ]))
        try run("ls", ["-o"])

        XCTAssertEqual(context.messages, [
            "-rw-r--r--         -  semel.machine.config  [not pushed]",
            "-rw-r--r--         -  hello  [not produced]",
        ])
    }

    func test_lsWithAnExplicitFileSystemIsRootRelative() throws {
        context.currentDirectoryPath = Path("src")
        connection.reply(.list(entries: []))

        try run("ls", ["-o", "*.o"])

        XCTAssertEqual(connection.daemonRequests, [.list(fileSystem: .output, pattern: "*.o")])
        XCTAssertEqual(context.messages, ["(empty)"])
    }

    func test_cdIntoAFolderChangesTheDirectory() throws {
        connection.reply(.list(entries: [ListEntry(path: "src", kind: .folder, size: nil, mode: nil, status: .none)]))

        try run("cd", ["src"])

        XCTAssertEqual(connection.daemonRequests, [.list(fileSystem: .input, pattern: "src")])
        XCTAssertEqual(context.currentDirectoryPath, Path("src"))
        XCTAssertEqual(context.messages, ["input:/src"])
    }

    func test_cdWithAWildcardLandsOnTheMatchedFolder() throws {
        connection.reply(.list(entries: [ListEntry(path: "src", kind: .folder, size: nil, mode: nil, status: .none)]))

        try run("cd", ["sr*"])

        XCTAssertEqual(connection.daemonRequests, [.list(fileSystem: .input, pattern: "sr*")])
        XCTAssertEqual(context.currentDirectoryPath, Path("src"))
        XCTAssertEqual(context.messages, ["input:/src"])
    }

    func test_cdIntoAMissingFolderIsAnError() throws {
        connection.reply(.list(entries: []))

        try run("cd", ["nope"])

        XCTAssertEqual(context.currentDirectoryPath, .empty)
        XCTAssertEqual(context.errors, ["cd: nope: no such directory"])
    }

    func test_cdWithAFileSystemFlagGoesToItsRoot() throws {
        context.currentDirectoryPath = Path("src")

        try run("cd", ["-o"])

        XCTAssertEqual(context.currentFileSystem, .output)
        XCTAssertEqual(context.currentDirectoryPath, .empty)
        XCTAssertEqual(context.messages, ["output:"])
    }
}
