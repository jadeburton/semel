//
//  WatcherTests.swift
//  SemelWatchTests
//
//  B-126. The whole watcher but its two adapters: a stream fed by hand, a temporary
//  directory for a disk, and a real engine behind an in-process connection — what a save
//  does, from the event to `input:`.
//
//  On `XCTestCase`, as every test in this package is: `SemelCoreTestCase` lives in the
//  engine package's own test target, which nothing here can depend on, so the process
//  globals are isolated by hand, as `SemelCLITests` isolates them.
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelNodeKit
import SemelProtocol
import SemelServer
@testable import SemelWatch
import XCTest

final class WatcherTests: XCTestCase {

    private var base: URL?
    private var store: URL?
    private var engine: BuildEngine?
    private var handler: RequestHandler?
    private var lines: [String] = []
    private let linesLock = NSLock()

    override func setUpWithError() throws {
        try super.setUpWithError()
        let store = try makeTemporaryDirectory()
        self.store = store
        DataObjectStore.shared = DataObjectStore(storeRoot: store)
        base = try makeTemporaryDirectory()
        let database = try DatabaseLayer()
        let engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.startProcessingLoop()
        self.engine = engine
        handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
    }

    override func tearDownWithError() throws {
        engine?.stopProcessingLoop()
        engine = nil
        BuildEngine.shared = nil
        handler = nil
        for directory in [base, store].compactMap({ $0 }) {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    // MARK: - What a save does

    /// A file written and then reported reaches `input:` with its bytes and its mode, as a
    /// `push` would have sent them.
    func test_aFileWrittenThenReportedReachesInputWithItsBytesAndMode() throws {
        try write("echo hello", at: "src/run.sh", mode: 0o755)
        let clock = ManualClock()
        let watcher = try makeWatcher(folders: ["src"], pushesInitially: false, clock: clock,
                                      events: [ManualEvents.reporting("src/run.sh")])

        try watcher.run()

        let (mode, bytes) = try fetch("src/run.sh")
        XCTAssertEqual(bytes, Data("echo hello".utf8))
        XCTAssertEqual(mode, 0o755)
        XCTAssertEqual(watcher.batchesIssued, 1)
        XCTAssertTrue(lines.contains("Push file: src/run.sh"), lines.joined(separator: "\n"))
    }

    /// A file removed and then reported is gone from `input:` — the watcher is a mirror,
    /// where a push only adds — and a folder removed is gone whole.
    func test_aFileRemovedThenReportedIsGoneFromInput() throws {
        try write("int a;", at: "src/a.c")
        try write("int b;", at: "src/b.c")
        try write("int c;", at: "src/old/c.c")
        let watcher = try makeWatcher(folders: ["src"], events: [ManualEvents.reporting("src/b.c", "src/old/c.c", "src/old")])
        // The initial push runs before the first event is read, so the files are removed
        // from disk once the watcher has pushed them: here, from the stream's first wait.
        removeOnFirstWait = ["src/b.c", "src/old"]

        try watcher.run()

        let interpreter = CommandInterpreter(connection: InProcessConnection(handler: try XCTUnwrap(handler)))
        XCTAssertTrue(try interpreter.inputHolds("src/a.c"))
        XCTAssertFalse(try interpreter.inputHolds("src/b.c"))
        XCTAssertFalse(try interpreter.inputHolds("src/old"))
        XCTAssertTrue(lines.contains("Removed folder: src/old"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("Removed file: src/b.c"), lines.joined(separator: "\n"))
    }

    /// Two bursts with a quiet interval between them are two batches, each settled before
    /// the next is pushed.
    func test_twoBurstsAreTwoBatchesAndTwoSettles() throws {
        try write("int a;", at: "src/a.c")
        try write("int b;", at: "src/b.c")
        let watcher = try makeWatcher(folders: ["src"], pushesInitially: false, clock: ManualClock(),
                                      events: [ManualEvents.reporting("src/a.c"), .quiet, ManualEvents.reporting("src/b.c")])

        try watcher.run()

        XCTAssertEqual(watcher.batchesIssued, 2)
        XCTAssertEqual(lines.filter { $0 == "Settled." }.count, 2, lines.joined(separator: "\n"))
        let pushes = lines.filter { $0.hasPrefix("Push file:") }
        XCTAssertEqual(pushes, ["Push file: src/a.c", "Push file: src/b.c"])
    }

    /// The line at launch names the base and every folder watched, and what is excepted,
    /// so that a filter excepting the file being edited is seen at once.
    func test_theLaunchLineNamesWhatIsWatched() throws {
        let base = try XCTUnwrap(self.base)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Packages"), withIntermediateDirectories: true)
        let watcher = try makeWatcher(folders: ["Packages"], only: ["**/*.swift"], except: ["**/Tests/**"],
                                      pushesInitially: false, events: [])

        try watcher.run()

        XCTAssertTrue(lines.contains("Watching Packages under \(base.path); only **/*.swift; "
                                     + "except **/Tests/**, semel-out/; a batch after 2 s of quiet."),
                      lines.joined(separator: "\n"))
    }

    /// The initial push is what `push <folder>` would do; a save after it of a file that
    /// did not change is pushed and reported unchanged, and nothing is exported when no
    /// destination was given.
    func test_theInitialPushHoldsTheTreeBeforeTheFirstChange() throws {
        try write("int a;", at: "src/a.c")
        let watcher = try makeWatcher(folders: ["src"], events: [ManualEvents.reporting("src/a.c")])

        try watcher.run()

        XCTAssertEqual(watcher.batchesIssued, 2)
        XCTAssertEqual(lines.filter { $0.hasPrefix("Push file: src/a.c") },
                       ["Push file: src/a.c", "Push file: src/a.c [no change]"])
        XCTAssertFalse(lines.contains { $0.hasPrefix("Exported") })
    }

    /// With a destination, each settle without errors is followed by an export of the
    /// watched folder — here a folder with no products, which `export` says.
    func test_aDestinationIsExportedIntoAfterASettleWithoutErrors() throws {
        try write("int a;", at: "src/a.c")
        let destination = try XCTUnwrap(base).appendingPathComponent("out").path
        let watcher = try makeWatcher(folders: ["src"], exportDestination: destination, events: [])

        try watcher.run()

        XCTAssertTrue(lines.contains("export: src: no such folder in the output file system"), lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private var removeOnFirstWait: [String] = []

    private func makeWatcher(folders: [Path], only: [String] = [], except: [String] = [],
                             exportDestination: String? = nil, pushesInitially: Bool = true,
                             clock: ManualClock = ManualClock(), events: [ManualEvents.Item]) throws -> Watcher {
        let base = try XCTUnwrap(self.base)
        let handler = try XCTUnwrap(self.handler)
        let configuration = WatchConfiguration(base: base.path, folders: folders, only: only, except: except,
                                               exportDestination: exportDestination, pushesInitially: pushesInitially)
        let stream = RemovingEvents(clock: clock, events) { [weak self] in
            guard let self else {
                return
            }
            for path in self.removeOnFirstWait {
                try? FileManager.default.removeItem(at: base.appendingPathComponent(path))
            }
            self.removeOnFirstWait = []
        }
        let watcher = Watcher(configuration: configuration, events: stream, clock: clock,
                              connector: InProcessConnector(handler: handler, base: base.path))
        watcher.output = { [weak self] line in
            guard let self else {
                return
            }
            self.linesLock.withLock { self.lines.append(line) }
        }
        return watcher
    }

    private func write(_ text: String, at path: String, mode: Int = 0o644) throws {
        let file = try XCTUnwrap(base).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }

    /// The bytes and mode `input:` holds at `path`.
    private func fetch(_ path: String) throws -> (UInt16, Data) {
        let connection = InProcessConnection(handler: try XCTUnwrap(handler))
        let (response, body) = try connection.send(.daemon(.fetch(fileSystem: .input, path: path)), body: nil)
        guard case .daemon(.fetch(let mode)) = response else {
            XCTFail("no file at input:/\(path): \(response)")
            return (0, Data())
        }
        return (mode, body ?? Data())
    }
}

/// A connection to the test's engine with an interpreter over it, as `semel-watch` opens
/// one over a socket.
private struct InProcessConnector: WatchConnector {
    let handler: RequestHandler
    let base: String

    func connect() throws -> WatchSession {
        let connection  = InProcessConnection(handler: handler)
        let interpreter = CommandInterpreter(connection: connection, baseDirectory: base)
        let (serverVersion, databasePath) = try interpreter.connect()
        return WatchSession(interpreter: interpreter, serverVersion: serverVersion, databasePath: databasePath,
                            isOpen: { true })
    }
}

/// The hand-fed stream, with one thing done to the disk at its first wait: after the
/// initial push and before the first event is read.
private final class RemovingEvents: FileEvents {
    private let events: ManualEvents
    private var onFirstWait: (() -> Void)?

    init(clock: ManualClock, _ queue: [ManualEvents.Item], onFirstWait: @escaping () -> Void) {
        events = ManualEvents(clock: clock, queue)
        self.onFirstWait = onFirstWait
    }

    func next(waitingAtMost timeout: Duration?) -> FileEventsYield {
        onFirstWait?()
        onFirstWait = nil
        return events.next(waitingAtMost: timeout)
    }

    func stop() {
        events.stop()
    }

    var isStopped: Bool { events.isStopped }
}
