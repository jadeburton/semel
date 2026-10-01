//
//  RecordingConnection.swift
//  SemelCLITests
//
//  A connection that answers from a script and remembers what it was asked, so a plugin
//  can be tested on what it sends and how it renders the reply, with no engine anywhere.
//

@testable import SemelCLI
import Foundation
import SemelNodeKit
import SemelProtocol

/// Where `RecordingConnection` and `TestCommandContext` both note what they did, so a test
/// can pin the *order* of two calls across the two fakes — not just that each happened.
final class OrderLog {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
}

final class RecordingConnection: SemelConnection {

    private(set) var requests: [(request: Request, body: Data?)] = []
    var responses: [(response: Response, body: Data?)] = []
    var onEvent: ((Event) -> Void)?
    var orderLog: OrderLog?

    func send(_ request: Request, body: Data?) throws -> (Response, Data?) {
        orderLog?.record("send")
        requests.append((request, body))
        guard !responses.isEmpty else {
            return (.daemon(.ok), nil)
        }
        let scripted = responses.removeFirst()
        return (scripted.response, scripted.body)
    }

    /// Queue one daemon reply.
    func reply(_ response: DaemonResponse, body: Data? = nil) {
        responses.append((.daemon(response), body))
    }

    var daemonRequests: [DaemonRequest] {
        requests.compactMap { entry in
            if case .daemon(let request) = entry.request { return request }
            return nil
        }
    }
}

/// A `CommandContext` over a fake connection that captures output instead of printing it.
final class TestCommandContext: CommandContext {

    let connection: any SemelConnection
    var baseDirectory: String
    var currentFileSystem: FileSystemForCommand = .input
    var currentDirectoryPath: Path = .empty
    var openBatchDepth = 0
    var pushExclusions: Set<String> = [CommandInterpreter.defaultExportFolder]

    private(set) var messages: [String] = []
    private(set) var errors: [String] = []
    private(set) var countedErrorRecords: [[ErrorRecord]] = []
    private(set) var resetErrorRecordAccountingCallCount = 0
    var orderLog: OrderLog?

    var allOutput: [String] { messages + errors }

    init(connection: any SemelConnection, baseDirectory: String = NSTemporaryDirectory()) {
        self.connection    = connection
        self.baseDirectory = baseDirectory
    }

    func outputMessage(_ message: String) { messages.append(message) }
    func outputError(_ message: String)   { errors.append(message) }

    func countErrorRecords(_ records: [ErrorRecord]) { countedErrorRecords.append(records) }

    func resetErrorRecordAccounting() {
        resetErrorRecordAccountingCallCount += 1
        orderLog?.record("resetErrorRecordAccounting")
    }

    func settleWaitBegan() { orderLog?.record("settleWaitBegan") }
    func settleWaitEnded() { orderLog?.record("settleWaitEnded") }

    var settleInProgress: ProgressRecord?
    var settlesFinished = 0
    var keyReader: any KeyReader = ScriptedKeyReader()
    var watcherLauncher: any WatcherLauncher = RecordingWatcherLauncher()
    var runningWatcher: RunningWatcher?
}

/// A launcher that starts nothing: it records each launch's arguments and hands back a
/// watcher that only notes whether it was stopped (B-126).
final class RecordingWatcherLauncher: WatcherLauncher {
    private(set) var launches: [[String]] = []
    private(set) var launched: [RecordedWatcher] = []

    func launch(arguments: [String]) throws -> any LaunchedWatcher {
        launches.append(arguments)
        let watcher = RecordedWatcher(processIdentifier: Int32(4200 + launched.count))
        launched.append(watcher)
        return watcher
    }
}

final class RecordedWatcher: LaunchedWatcher {
    let processIdentifier: Int32
    private(set) var isRunning = true

    init(processIdentifier: Int32) {
        self.processIdentifier = processIdentifier
    }

    func stop() {
        isRunning = false
    }

    /// As a watcher that ended by itself — its engine unreachable, its folder gone.
    func exitOnItsOwn() {
        isRunning = false
    }
}

/// A key reader that plays a script instead of reading a terminal: whether there is one,
/// and what happens while the command waits — a key at once, a settle finishing first, a
/// failure. Notes the wait in the shared `OrderLog`, so a test can pin what brackets it.
final class ScriptedKeyReader: KeyReader {

    var isTerminal = true
    var orderLog: OrderLog?
    private(set) var waits = 0

    /// What happens during the wait. Handed the caller's `stop`, so a script can make
    /// something happen and then ask whether the caller has seen it. A key, by default.
    var script: (() -> Bool) throws -> KeyWait = { _ in .keyPressed }

    func waitForKey(orUntil stop: () -> Bool) throws -> KeyWait {
        waits += 1
        orderLog?.record("waitForKey")
        return try script(stop)
    }
}
