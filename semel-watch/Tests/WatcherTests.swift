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
        // Settled before it is stopped: a pass still running writes into the store this
        // teardown removes, and the removal fails on what appears behind it.
        engine?.waitUntilIdleBlocking()
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

    /// A file pushed and then deleted while no watcher ran is gone from `input:` after the
    /// initial batch — its `rm` and the folder's push in one `begin` … `commit`, so one
    /// settle — and the launch line says so.
    func test_theInitialBatchRemovesWhatTheDiskNoLongerHas() throws {
        try write("int a;", at: "src/a.c")
        try write("int b;", at: "src/b.c")
        try pushBeforeLaunch("src")
        try FileManager.default.removeItem(at: try XCTUnwrap(base).appendingPathComponent("src/b.c"))
        let watcher = try makeWatcher(folders: ["src"], events: [])

        try watcher.run()

        let interpreter = CommandInterpreter(connection: InProcessConnection(handler: try XCTUnwrap(handler)))
        XCTAssertTrue(try interpreter.inputHolds("src/a.c"))
        XCTAssertFalse(try interpreter.inputHolds("src/b.c"))
        XCTAssertEqual(watcher.batchesIssued, 1)
        XCTAssertEqual(lines.filter { $0 == "Settled." }.count, 1, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("Removed file: src/b.c"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("Watching src") && $0.hasSuffix("; removing 1 path the disk no longer has.") },
                      lines.joined(separator: "\n"))
    }

    /// `--no-initial` skips the initial batch whole: what the disk no longer has stays.
    func test_noInitialLeavesWhatTheDiskNoLongerHas() throws {
        try write("int b;", at: "src/b.c")
        try pushBeforeLaunch("src")
        try FileManager.default.removeItem(at: try XCTUnwrap(base).appendingPathComponent("src/b.c"))
        let watcher = try makeWatcher(folders: ["src"], pushesInitially: false, events: [])

        try watcher.run()

        let interpreter = CommandInterpreter(connection: InProcessConnection(handler: try XCTUnwrap(handler)))
        XCTAssertTrue(try interpreter.inputHolds("src/b.c"))
        XCTAssertEqual(watcher.batchesIssued, 0)
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

    /// B-142. A settle that leaves errors exports what has a value into the destination —
    /// here nothing, since the one product has none — and the report ends with the summary
    /// that says so.
    func test_aSettleWithErrorsReportsWhatItExported() throws {
        try write("int a;", at: "src/a.c")
        _ = try XCTUnwrap(engine).inputFileSystem.ensureEntirePathExistsAsFolders(Path("stand-in"), pinned: true)
        let (source, _) = try GraphSpecNode.staticFile(at: "input:/stand-in/broken.a").findOrCreateMatchingNode()
        _ = try GraphSpecNode(OutputFile.self, properties: [OutputFile.pathProperty: "output:/src/broken.a"],
                              inputs: [OutputFile.inputPort: ["product": .staticFile(at: "input:/stand-in/broken.a")]])
            .findOrCreateMatchingNode()
        try source.writeToOutputPort(StaticFile.outputPort,
                                     value: .noValue(reason: try .failure("gone")))
        let destination = try XCTUnwrap(base).appendingPathComponent("out").path
        let watcher = try makeWatcher(folders: ["src"], exportDestination: destination, events: [])

        try watcher.run()

        XCTAssertTrue(lines.contains("broken.a:"), lines.joined(separator: "\n"))
        XCTAssertEqual(lines.last, "1 error · 1 product without a value · nothing exported", lines.joined(separator: "\n"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("Exported") })
    }

    // MARK: - Locked folders (B-146)

    /// `app/Dependencies/Pkg` vendored with the lock `prepare` writes beside it, both in
    /// `input:` before the watcher starts.
    private func vendorLockedPackage() throws {
        try write("public struct Pkg {}\n", at: "app/Dependencies/Pkg/Pkg.swift")
        try writeLock()
        try write("print(1)\n", at: "app/src/main.swift")
        try pushBeforeLaunch("app")
    }

    private func writeLock() throws {
        let root = try FolderContentRoot.root(ofFolderAt: try XCTUnwrap(base).appendingPathComponent("app/Dependencies/Pkg"))
        try write(DependencyLock(contentRoot: root, fold: FolderContentRoot.formatTag).text,
                  at: "app/Dependencies/Pkg.semel-lock")
    }

    private func heldText(_ path: String) throws -> String {
        String(decoding: try fetch(path).1, as: UTF8.self)
    }

    /// A locked folder is not watched unless an `--only` names it, and the launch line says
    /// which and how they change: an edit below one is never pushed.
    func test_aLockedFolderIsNotWatchedByDefaultAndTheLaunchLineSaysSo() throws {
        try vendorLockedPackage()
        writeOnFirstWait = [("app/Dependencies/Pkg/Pkg.swift", "public struct Pkg { let edited = true }\n")]
        let watcher = try makeWatcher(folders: ["app"], pushesInitially: false,
                                      events: [ManualEvents.reporting("app/Dependencies/Pkg/Pkg.swift")])

        try watcher.run()

        XCTAssertTrue(lines.contains { $0.contains("; not watching the locked app/Dependencies/Pkg, which change only with "
                                                    + "their locks: `semel-swift prepare` vendors them again;") },
                      lines.joined(separator: "\n"))
        XCTAssertEqual(watcher.batchesIssued, 0, "an edit below a locked folder is no batch at all")
        XCTAssertEqual(try heldText("app/Dependencies/Pkg/Pkg.swift"), "public struct Pkg {}\n")
    }

    /// The initial mirror leaves a locked folder alone too, so a copy edited by hand while
    /// no watcher ran does not have the whole launch refused.
    func test_theInitialMirrorLeavesALockedFolderAlone() throws {
        try vendorLockedPackage()
        try write("public struct Pkg { let edited = true }\n", at: "app/Dependencies/Pkg/Pkg.swift")
        try write("print(2)\n", at: "app/src/main.swift")
        let watcher = try makeWatcher(folders: ["app"], events: [])

        try watcher.run()

        XCTAssertEqual(watcher.batchesRefused, 0, lines.joined(separator: "\n"))
        XCTAssertEqual(try heldText("app/src/main.swift"), "print(2)\n")
        XCTAssertEqual(try heldText("app/Dependencies/Pkg/Pkg.swift"), "public struct Pkg {}\n")
    }

    /// A re-vendor — the copy and its lock changed in one quiet interval — lands: the lock's
    /// change brings its folder with it.
    func test_aReVendorOfCopyAndLockInOneIntervalLands() throws {
        try vendorLockedPackage()
        writeOnFirstWait = [("app/Dependencies/Pkg/Pkg.swift", "public struct Pkg { let version = 2 }\n")]
        relockOnFirstWait = true
        let watcher = try makeWatcher(folders: ["app"], pushesInitially: false,
                                      events: [ManualEvents.reporting("app/Dependencies/Pkg/Pkg.swift",
                                                                      "app/Dependencies/Pkg.semel-lock")])

        try watcher.run()

        XCTAssertEqual(watcher.batchesRefused, 0, lines.joined(separator: "\n"))
        XCTAssertEqual(try heldText("app/Dependencies/Pkg/Pkg.swift"), "public struct Pkg { let version = 2 }\n")
    }

    /// Told to watch a locked folder, the watcher pushes an edit below it, the barrier
    /// refuses the batch, and the refusal is reported as the error it is; the next save of
    /// anything else is a batch of its own and builds.
    func test_anEditUnderAWatchedLockedFolderIsRefusedAndTheNextSaveStillLands() throws {
        try vendorLockedPackage()
        writeOnFirstWait = [("app/Dependencies/Pkg/Pkg.swift", "public struct Pkg { let edited = true }\n"),
                            ("app/src/main.swift", "print(2)\n")]
        let watcher = try makeWatcher(folders: ["app"], only: ["app/Dependencies/Pkg/**/*", "app/src/**/*"],
                                      pushesInitially: false, clock: ManualClock(),
                                      events: [ManualEvents.reporting("app/Dependencies/Pkg/Pkg.swift"), .quiet,
                                               ManualEvents.reporting("app/src/main.swift")])

        try watcher.run()

        XCTAssertEqual(watcher.batchesIssued, 2)
        XCTAssertEqual(watcher.batchesRefused, 1)
        XCTAssertTrue(lines.contains { $0.hasPrefix("app/Dependencies/Pkg is locked, and the batch changes it") },
                      lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("semel-watch: the batch was not committed; nothing was built or exported from it."))
        XCTAssertEqual(try heldText("app/Dependencies/Pkg/Pkg.swift"), "public struct Pkg {}\n")
        XCTAssertEqual(try heldText("app/src/main.swift"), "print(2)\n")
    }

    // MARK: - Helpers

    private var removeOnFirstWait: [String] = []
    private var writeOnFirstWait: [(path: String, text: String)] = []
    private var relockOnFirstWait = false

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
            for (path, text) in self.writeOnFirstWait {
                try? self.write(text, at: path)
            }
            self.writeOnFirstWait = []
            if self.relockOnFirstWait {
                try? self.writeLock()
                self.relockOnFirstWait = false
            }
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

    /// `push` and `wait` from a session of its own, as a person would have run them before
    /// the watcher was started; what it prints is not the watcher's.
    private func pushBeforeLaunch(_ paths: String...) throws {
        let interpreter = CommandInterpreter(connection: InProcessConnection(handler: try XCTUnwrap(handler)),
                                             baseDirectory: try XCTUnwrap(base).path)
        interpreter.output = { _ in }
        _ = try interpreter.connect()
        interpreter.handleCommand(verb: "push", arguments: paths)
        interpreter.handleCommand(verb: "wait", arguments: [])
        for path in paths {
            XCTAssertTrue(try interpreter.inputHolds(path), "\(path) was not pushed")
        }
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
