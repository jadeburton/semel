//
//  ManagedProcess.swift
//  SemelTestSupport
//
//  One subprocess with its output kept: stdout and stderr on one pipe, read as it
//  arrives so a process that prints thousands of lines never blocks on a full pipe, and
//  a wait with a deadline so a hung process fails a test instead of hanging it.
//

import Foundation

public final class ManagedProcess {

    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var collected = Data()

    /// The launch, as a shell would show it, for a failure message.
    public let commandLine: String

    public init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = pipe
        process.standardError  = pipe
        commandLine = ([executable.path] + arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }).joined(separator: " ")
    }

    public func start() throws {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                return
            }
            self.lock.lock()
            self.collected.append(data)
            self.lock.unlock()
        }
        try process.run()
    }

    public var isRunning: Bool { process.isRunning }

    public var terminationStatus: Int32 { process.terminationStatus }

    /// Everything the process has written so far, both streams interleaved as they came.
    public var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: collected, as: UTF8.self)
    }

    /// The last `count` lines of `output`, for a failure message.
    public func outputTail(_ count: Int = 40) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
    }

    /// Waits up to `timeout` for the process to exit. Returns its status, or nil when it
    /// is still running at the deadline. Reads what is left on the pipe once it has
    /// exited, so `output` is complete when this returns a status.
    public func waitForExit(timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                return nil
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        collected.append(rest)
        lock.unlock()
        return process.terminationStatus
    }

    /// SIGTERM.
    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    /// SIGKILL, for a process that ignored SIGTERM.
    public func kill() {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}

public enum SocketWait {

    /// Polls for the socket file `semelserv` creates when it is ready to accept.
    public static func wait(forSocketAt path: String, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
