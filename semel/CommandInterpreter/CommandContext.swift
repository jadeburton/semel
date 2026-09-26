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
}

/// A failure the server reported. Thrown by `request` so the interpreter prints it the way
/// it prints any command failure.
struct ServerError: Error, CustomStringConvertible {
    let response: ErrorResponse

    var description: String {
        switch response {
        case .pathNotFound(let path):          return "\(path): no such file or directory"
        case .notAFolder(let path):            return "\(path): not a directory"
        case .nodeError(let description):      return description
        case .roleNotOffered(let role):        return "the server does not offer the \(role.rawValue) role"
        case .malformedRequest(let description): return "the server could not read the request: \(description)"
        case .replyTooLarge(let request, let bytes, let limit):
            return "the server's reply to `\(request)` is \(bytes) bytes, over the \(limit)-byte limit for one reply; "
                 + "ask for less of the graph at a time, or report the verb as needing a reply that streams"
        case .unrecoverable(let message):      return "the server stopped: \(message)"
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
        switch response {
        case .daemon(let daemonResponse):
            return (daemonResponse, replyBody)
        case .error(let error):
            throw ServerError(response: error)
        case .hello:
            throw ServerError(response: .malformedRequest(description: "a hello reply to a daemon request"))
        }
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
