// WatcherLauncher.swift
// semel
//
// What `watch <folder>` starts (B-126): a `semel-watch` for the session's base, as a child
// of the prompt. Behind a protocol so a test records the launch instead of making one.

import Foundation

/// Starts a `semel-watch` with the arguments it is given.
public protocol WatcherLauncher {
    func launch(arguments: [String]) throws -> any LaunchedWatcher
}

/// A watcher the prompt started.
public protocol LaunchedWatcher: AnyObject {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    /// Ends it, and returns once it has gone.
    func stop()
}

/// The watcher a session has running, and the folder it was asked to watch.
struct RunningWatcher {
    let folder: String
    let process: any LaunchedWatcher
}

/// The executable beside this one, as `ServerLauncher` finds `semelserv`: the prompt does
/// not link the watcher, so the two stay separately testable, and a watcher started from a
/// script is the same program as one started here.
public struct ProcessWatcherLauncher: WatcherLauncher {

    public enum Failure: Error, CustomStringConvertible {
        case noWatcherBeside(executable: String)

        public var description: String {
            switch self {
            case .noWatcherBeside(let executable):
                return "no `semel-watch` beside \(executable); build it, or run one yourself"
            }
        }
    }

    public init() {}

    /// The `semel-watch` built beside this executable, or nil when there is none.
    static func watcherExecutable() -> URL? {
        guard let own = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let candidate = own.deletingLastPathComponent().appendingPathComponent("semel-watch")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// Its output is the prompt's — standard output and standard error inherited — so its
    /// lines interleave with the prompt's as the subscription's events already do. Its
    /// input is not: the keyboard is the prompt's.
    public func launch(arguments: [String]) throws -> any LaunchedWatcher {
        guard let executable = Self.watcherExecutable() else {
            throw Failure.noWatcherBeside(executable: Bundle.main.executableURL?.path ?? "semel")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments     = arguments
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return ChildWatcher(process: process)
    }
}

/// A `semel-watch` running as a child process.
final class ChildWatcher: LaunchedWatcher {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var processIdentifier: Int32 { process.processIdentifier }

    var isRunning: Bool { process.isRunning }

    /// SIGTERM, which the watcher answers by ending its stream; SIGKILL if it has not gone
    /// by the time it should have, a batch's settle included.
    func stop() {
        guard process.isRunning else {
            return
        }
        process.terminate()
        let patience: TimeInterval = 5
        let deadline = Date().addingTimeInterval(patience)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}
