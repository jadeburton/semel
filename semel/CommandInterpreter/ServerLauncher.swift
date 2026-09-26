//
//  ServerLauncher.swift
//  semel
//
//  The engine starts itself (B-110). A `semel` that finds no server at the socket starts
//  `semelserv` — the executable beside its own — and connects once the socket answers.
//  The daemon is left running: a resident graph is the point, and the next `semel` finds
//  it warm. `semel stop` ends it, by the same means a removed socket file does (B-73).
//

import Foundation
import SemelNodeKit

public enum ServerLauncher {

    public enum Failure: Error, CustomStringConvertible {
        case noServerBeside(executable: String)
        case didNotAnswer(socketPath: String, log: String, tail: String)

        public var description: String {
            switch self {
            case .noServerBeside(let executable):
                return "no `semelserv` beside \(executable); build both, or start one yourself"
            case .didNotAnswer(let socketPath, let log, let tail):
                return "started semelserv, but nothing answers at \(socketPath); its log is \(log)"
                     + (tail.isEmpty ? "" : ":\n\(tail)")
            }
        }
    }

    /// Where the daemon's output goes: beside the graph, so `SEMEL_HOME` moves both.
    public static var logPath: String {
        SemelPaths.root.appendingPathComponent("semelserv.log").path
    }

    /// The `semelserv` built beside this executable, or nil when there is none.
    public static func serverExecutable() -> URL? {
        guard let own = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let candidate = own.deletingLastPathComponent().appendingPathComponent("semelserv")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// Starts `semelserv` detached and returns a connection to it once it answers.
    ///
    /// Detached through `nohup … &` under `/bin/sh`: the daemon must outlive this process
    /// and the terminal it was started from, and a child of this process would go with
    /// either. The environment passes through, so `SEMEL_HOME` and `SEMEL_SOCKET` place
    /// the daemon where this client expects it.
    ///
    /// Two clients starting a server at once is the race `Server.claimSocket` already
    /// settles: the second finds the socket answering and exits, and both clients connect
    /// to the first.
    public static func start(socketPath: String,
                             timeout: TimeInterval = 15,
                             say: (String) -> Void) throws -> SocketConnection {
        guard let server = serverExecutable() else {
            throw Failure.noServerBeside(executable: Bundle.main.executableURL?.path ?? "semel")
        }
        let log = logPath
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: log).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", #"nohup "$0" >> "$1" 2>&1 &"#, server.path, log]
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError  = FileHandle.nullDevice
        try shell.run()
        shell.waitUntilExit()

        say("Started semelserv (log: \(log))")

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let connection = try? SocketConnection.connect(to: socketPath, timeout: 1) {
                return connection
            }
            guard Date() < deadline else {
                throw Failure.didNotAnswer(socketPath: socketPath, log: log, tail: tail(of: log))
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Stops the daemon at `socketPath`: removing the socket file is the orderly stop the
    /// server watches for (B-73). Says what it did; a daemon that was not running is not
    /// an error, since the state asked for is the state there is.
    public static func stop(socketPath: String, say: (String) -> Void) {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            say("No server running at \(socketPath).")
            return
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        say("Stopping semelserv at \(socketPath).")
    }

    /// The last few lines of the log, for a failure to show.
    private static func tail(of log: String) -> String {
        guard let text = try? String(contentsOfFile: log, encoding: .utf8) else {
            return ""
        }
        return text.split(separator: "\n").suffix(5).joined(separator: "\n")
    }
}
