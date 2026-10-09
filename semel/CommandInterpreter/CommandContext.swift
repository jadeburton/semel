// CommandContext.swift
// semel
//
// What a command plugin sees: the session's state, a way to print, and one connection to
// whatever holds the graph. Nothing here knows whether that is the same process or a
// socket away.

import Foundation
import SemelNodeKit
import SemelProtocol

protocol CommandContext: AnyObject {
    var connection: any SemelConnection { get }
    var baseDirectory: String { get set }
    var currentFileSystem: FileSystemForCommand { get set }
    var currentDirectoryPath: Path { get set }

    /// How many batches `begin` has opened and `commit` has not yet closed. The server
    /// keeps its own count per session; this one is what lets `wait` refuse instead of
    /// blocking on a signal the open batch is holding back.
    var openBatchDepth: Int { get set }

    /// Paths under `base`, relative to it, that `push` never sends: where `build` exports
    /// its products. Yesterday's products must not arrive as today's sources when the
    /// tree above them is pushed (B-110).
    var pushExclusions: Set<String> { get set }

    func outputMessage(_ message: String)
    func outputError(_ message: String)

    /// Counts one non-empty settle report toward `errorsReported`, once since the last
    /// `resetErrorRecordAccounting()` — the reset is per `wait`. The idle-time event and
    /// the `errors` verb the `build` macro runs right after it usually name the very same
    /// failures, and counting both would make one broken build look like two.
    func countErrorRecords(_ records: [ErrorRecord])

    /// Allows the next `countErrorRecords` to count again. Called before every `wait`, so
    /// a later build against a graph that is still broken the same way is still counted —
    /// the engine's own idle-time report will not repeat a message it already delivered,
    /// so only this reset lets the following `errors` verb's query count it again.
    func resetErrorRecordAccounting()

    /// A command is about to block until the graph settles: the progress line may be
    /// drawn from here until `settleWaitEnded()` (B-95). Bracketing the wait rather than
    /// the command, so the result the command prints lands on a clean line.
    func settleWaitBegan()
    func settleWaitEnded()

    /// Where the settle under way stood at the last progress event this client heard; nil
    /// when the last settle it heard of has finished, or it has heard of none. What `watch`
    /// says when a key ends it, and what the progress line starts from.
    var settleInProgress: ProgressRecord? { get }

    /// How many settles this client has heard finish. `watch` ends when it moves.
    var settlesFinished: Int { get }

    /// The key that ends a `watch`: the terminal in the client, a script in a test.
    var keyReader: any KeyReader { get }

    /// What `watch <folder>` starts a `semel-watch` with: a process beside this one in the
    /// client, a recorder in a test (B-126).
    var watcherLauncher: any WatcherLauncher { get }

    /// The watcher `watch <folder>` started, until `unwatch`, `quit` or the next `watch
    /// <folder>` stops it. One per session.
    var runningWatcher: RunningWatcher? { get set }

    /// Whether error reports are drawn in colour: the terminal's to decide, at launch
    /// (`ColourPolicy`).
    var reportsInColour: Bool { get }
}

/// A failure the server reported. Thrown by `request` so the interpreter prints it the way
/// it prints any command failure.
struct ServerError: Error, CustomStringConvertible {
    let response: ErrorResponse

    var description: String {
        switch response {
        case .pathNotFound(let path):          return "\(path): no such file or directory"
        case .notAFolder(let path):            return "\(path): not a directory"
        case .notAProduct(let path):
            return "\(path): no product is published there; name a product under output:, or a tree product's folder"
        case .nodeError(let description):      return description
        case .roleNotOffered(let role):        return "the server does not offer the \(role.rawValue) role"
        case .malformedRequest(let description): return "the server could not read the request: \(description)"
        case .replyTooLarge(let request, let bytes, let limit):
            return "the server's reply to `\(request)` is \(bytes) bytes, over the \(limit)-byte limit for one reply; "
                 + "ask for less of the graph at a time, or report the verb as needing a reply that streams"
        case .unrecoverable(let message):      return "the server stopped: \(message)"
        // Locked folders and checkpoints (B-146).
        case .batchRejected(let folder, let lock, let expected, let found, let paths):
            return BatchRejectionRenderer.lines(folder: folder, lock: lock, expected: expected, found: found, paths: paths)
                .joined(separator: "\n")
        case .checkpointNotFound(let name, let known):
            return "there is no checkpoint named '\(name)'; "
                 + (known.isEmpty ? "`checkpoint` records one" : "there are \(known.joined(separator: ", "))")
        }
    }

    /// Whether the failure is the request's own — its path, the node it reached — so that a
    /// command working through many requests reports this one and goes on to the next. The
    /// rest are the server's or the protocol's, and no later request would fare better.
    var isTheRequestsOwn: Bool {
        switch response {
        case .pathNotFound, .notAFolder, .notAProduct, .nodeError, .batchRejected, .checkpointNotFound:
            return true
        case .roleNotOffered, .malformedRequest, .replyTooLarge, .unrecoverable:
            return false
        }
    }
}

extension CommandContext {

    var currentLocation: String {
        let fsName = currentFileSystem.rootName
        return currentDirectoryPath.isEmpty ? fsName : "\(fsName)/\(currentDirectoryPath)"
    }

    /// Sends one daemon request and unwraps the daemon reply. A server-reported failure
    /// becomes a thrown `ServerError`; any other kind of reply is a protocol bug.
    func request(_ request: DaemonRequest, body: Data? = nil) throws -> (DaemonResponse, Data?) {
        let (response, replyBody) = try connection.send(.daemon(request), body: body)
        return (try response.daemonReply(), replyBody)
    }

    /// `request`, for a reply that may stream (B-137): each part is handed to `onPart` as it
    /// arrives, and what returns is the last part alone — a caller that wants every item
    /// gathers them from the parts and the last together.
    func request(_ request: DaemonRequest, body: Data? = nil,
                 onPart: (DaemonResponse) throws -> Void) throws -> (DaemonResponse, Data?) {
        let (response, replyBody) = try connection.send(.daemon(request), body: body) { part in
            // The connection lets only a daemon case that streams through as a part.
            guard case .daemon(let daemonPart) = part else {
                return
            }
            try onPart(daemonPart)
        }
        return (try response.daemonReply(), replyBody)
    }

    /// `request`, without waiting for the reply: what returns is collected later, as
    /// `request` would have returned it. For a command with work of its own to do while the
    /// server answers — a push reading its next files from disk.
    func requestWithoutWaiting(_ request: DaemonRequest, body: Data? = nil) throws -> PendingDaemonReply {
        PendingDaemonReply(pending: try connection.sendWithoutWaiting(.daemon(request), body: body))
    }

    /// Runs `body` inside a `begin` … `commit` of its own, nested in the session's batch
    /// when one is open. The commit's failure is thrown, not swallowed: the outermost one
    /// is where the lock barrier refuses a batch (B-146), and a refused push is a failed
    /// command. A `body` that throws still has its batch closed, as best it can be.
    func inBatchOfItsOwn(_ body: () throws -> Void) throws {
        _ = try request(.beginBatch)
        do {
            try body()
        } catch {
            _ = try? request(.endBatch)
            throw error
        }
        _ = try request(.endBatch)
    }

    /// Resolves a user-supplied path string relative to `base`, handling `..` and `.`.
    /// A leading `/` is treated as the root of the current internal file system.
    func resolve(_ pathStr: String, relativeTo base: Path) -> Path {
        let isAbsolute = pathStr.hasPrefix("/")
        var segments = isAbsolute ? [] : base.segments
        for seg in Path(isAbsolute ? String(pathStr.dropFirst()) : pathStr).segments {
            switch seg {
            case "..": if !segments.isEmpty { segments.removeLast() }
            case ".":  break
            default:   segments.append(seg)
            }
        }
        return Path(segments: segments)
    }

    /// Returns the portion of `path` after `base`, falling back to the full path string.
    func relativeName(_ path: Path, to base: Path) -> String {
        path.relative(to: base)?.string ?? path.string
    }

    /// Stops the session's watcher, when there is one, and says so.
    func stopRunningWatcher() {
        guard let running = runningWatcher else {
            return
        }
        runningWatcher = nil
        guard running.process.isRunning else {
            outputMessage("The watcher of \(running.folder) had already stopped.")
            return
        }
        running.process.stop()
        outputMessage("Stopped watching \(running.folder).")
    }
}

/// A daemon request sent without waiting (`requestWithoutWaiting`). `reply()` blocks for
/// the reply and returns it as `request` would have: a failure the server reported is a
/// thrown `ServerError`.
struct PendingDaemonReply {
    let pending: PendingReply

    func reply() throws -> (DaemonResponse, Data?) {
        let (response, replyBody) = try pending.reply()
        return (try response.daemonReply(), replyBody)
    }
}

extension Response {

    /// A server-reported failure becomes a thrown `ServerError`; any other kind of reply is
    /// a protocol bug.
    fileprivate func daemonReply() throws -> DaemonResponse {
        switch self {
        case .daemon(let daemonResponse):
            return daemonResponse
        case .error(let error):
            throw ServerError(response: error)
        case .hello:
            throw ServerError(response: .malformedRequest(description: "a hello reply to a daemon request"))
        }
    }
}

// MARK: - CommandPlugin

protocol CommandPlugin {
    /// The verb strings this plugin handles (e.g. `["ls", "list"]`).
    var verbs: Set<String> { get }

    /// Parse `tokens` (everything after the verb) and execute the command.
    func handle(verb: String, tokens: [String], context: any CommandContext) throws
}

extension CommandPlugin {
    /// Consume a required `-i`/`-o` flag. Defaults to `.input` when absent.
    func parseFileSystemFlag(tokens: [String]) -> (FileSystemForCommand, [String]) {
        guard let first = tokens.first else {
            return (.input, tokens)
        }
        switch first {
        case "-i", "--input":  return (.input,  Array(tokens.dropFirst()))
        case "-o", "--output": return (.output, Array(tokens.dropFirst()))
        default:               return (.input,  tokens)
        }
    }

    /// Consume an optional `-i`/`-o` flag, returning `nil` when absent so callers
    /// can distinguish an explicit choice from "use current file system".
    func parseOptionalFileSystemFlag(tokens: [String]) -> (FileSystemForCommand?, [String]) {
        guard let first = tokens.first else {
            return (nil, tokens)
        }
        switch first {
        case "-i", "--input":  return (.input,  Array(tokens.dropFirst()))
        case "-o", "--output": return (.output, Array(tokens.dropFirst()))
        default:               return (nil,     tokens)
        }
    }
}
