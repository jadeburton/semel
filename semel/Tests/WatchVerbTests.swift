//
//  WatchVerbTests.swift
//  SemelCLITests
//
//  B-126. `watch <folder>` starts a `semel-watch` for the session's base, `unwatch` and
//  `quit` stop it, and `watch` alone is still the progress line. The launch is recorded,
//  not made: no process is started here.
//

@testable import SemelCLI
import Foundation
import SemelNodeKit
import XCTest

final class WatchVerbTests: XCTestCase {

    private var base: URL?
    private var context: TestCommandContext?
    private var launcher = RecordingWatcherLauncher()
    private let keyReader = ScriptedKeyReader()

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true)
        for folder in ["src", "lib"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        self.base = base
        let context = TestCommandContext(connection: RecordingConnection(), baseDirectory: base.path)
        launcher = RecordingWatcherLauncher()
        context.watcherLauncher = launcher
        context.keyReader = keyReader
        self.context = context
    }

    override func tearDownWithError() throws {
        if let base {
            try FileManager.default.removeItem(at: base)
        }
        try super.tearDownWithError()
    }

    private func run(_ verb: String, _ tokens: [String] = []) throws {
        let context = try XCTUnwrap(self.context)
        switch verb {
        case "quit": try SessionPlugin().handle(verb: verb, tokens: tokens, context: context)
        default:     try EnginePlugin().handle(verb: verb, tokens: tokens, context: context)
        }
    }

    /// `watch` with no folder keeps its meaning from B-95: the progress line until a key,
    /// and no watcher started.
    func test_watchAloneIsTheProgressLineAsBefore() throws {
        try run("watch")

        XCTAssertEqual(try XCTUnwrap(context).messages.first, EnginePlugin.watchBegins)
        XCTAssertEqual(keyReader.waits, 1)
        XCTAssertEqual(launcher.launches, [])
    }

    /// The session's base, the folder and the flags `build` takes, passed through; the
    /// reports left to the prompt, which prints them from its own subscription.
    func test_watchAFolderStartsTheWatcherWithTheBaseTheFolderAndTheFlags() throws {
        let context = try XCTUnwrap(self.context)
        let destination = ExternalPathSanitizer.expandPartialPath("out")

        try run("watch", ["src", "--into", "out", "--only", "**/*.c", "--except", "**/test_*.c"])

        XCTAssertEqual(launcher.launches, [[context.baseDirectory, "src", "--into", destination,
                                            "--only", "**/*.c", "--except", "**/test_*.c", "--no-reports"]])
        XCTAssertEqual(context.messages, ["Watching src under \(context.baseDirectory): semel-watch is process 4200; "
                                          + "`unwatch` stops it."])
        XCTAssertEqual(keyReader.waits, 0, "no progress line")
        XCTAssertEqual(context.runningWatcher?.folder, "src")
    }

    /// The folder is read as `push` reads one: from the session's current directory.
    func test_theFolderIsReadFromTheCurrentDirectory() throws {
        let context = try XCTUnwrap(self.context)
        try FileManager.default.createDirectory(at: try XCTUnwrap(base).appendingPathComponent("src/app"),
                                                withIntermediateDirectories: true)
        context.currentDirectoryPath = Path("src")

        try run("watch", ["app"])

        XCTAssertEqual(launcher.launches.first?[1], "src/app")
    }

    /// One watcher per session: a second `watch <folder>` stops the first, and says so.
    func test_aSecondWatchReplacesTheFirst() throws {
        let context = try XCTUnwrap(self.context)
        try run("watch", ["src"])

        try run("watch", ["lib"])

        XCTAssertEqual(launcher.launched.map(\.isRunning), [false, true])
        XCTAssertEqual(context.messages.suffix(2), ["Stopped watching src.",
                                                    "Watching lib under \(context.baseDirectory): semel-watch is "
                                                    + "process 4201; `unwatch` stops it."])
    }

    func test_unwatchStopsIt() throws {
        let context = try XCTUnwrap(self.context)
        try run("watch", ["src"])

        try run("unwatch")

        XCTAssertEqual(launcher.launched.map(\.isRunning), [false])
        XCTAssertNil(context.runningWatcher)
        XCTAssertEqual(context.messages.last, "Stopped watching src.")
    }

    /// Nothing to stop is the state asked for, not an error.
    func test_unwatchWithNoWatcherSaysSo() throws {
        let context = try XCTUnwrap(self.context)

        try run("unwatch")

        XCTAssertEqual(context.messages, ["No watcher is running."])
        XCTAssertEqual(context.errors, [])
    }

    /// A watcher that ended by itself is said to have, rather than stopped again.
    func test_unwatchOfAWatcherThatEndedSaysItHad() throws {
        let context = try XCTUnwrap(self.context)
        try run("watch", ["src"])
        try XCTUnwrap(launcher.launched.first).exitOnItsOwn()

        try run("unwatch")

        XCTAssertEqual(context.messages.last, "The watcher of src had already stopped.")
    }

    /// A watcher is a child of the prompt: leaving the prompt stops it.
    func test_quitStopsIt() throws {
        try run("watch", ["src"])

        XCTAssertThrowsError(try run("quit"))

        XCTAssertEqual(launcher.launched.map(\.isRunning), [false])
        XCTAssertEqual(try XCTUnwrap(context).messages.last, "Stopped watching src.")
    }

    func test_aFolderThatIsNotThereStartsNothing() throws {
        let context = try XCTUnwrap(self.context)

        try run("watch", ["docs"])

        XCTAssertEqual(context.errors, ["watch: docs: no such folder under \(context.baseDirectory)"])
        XCTAssertEqual(launcher.launches, [])
    }

    func test_whatWatchCannotReadIsRefused() {
        XCTAssertThrowsError(try run("watch", ["src", "--follow"]))
        XCTAssertThrowsError(try run("watch", ["src", "lib"]))
        XCTAssertThrowsError(try run("watch", ["src", "--into"]))
        XCTAssertThrowsError(try run("watch", ["--into", "out"]))
        XCTAssertThrowsError(try run("unwatch", ["src"]))
        XCTAssertEqual(launcher.launches, [])
    }
}
