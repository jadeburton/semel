// PushStatus.swift
// semel
//
// What a push is doing now, said on one line the indicator redraws in place (B-167). A push
// of a tree of twenty thousand files runs for tens of seconds before its one line of result,
// and the line is what moves meanwhile: reading the disk, then the files the server has
// recorded, then the commit. Drawn only where the progress line is (`ProgressPolicy`), so a
// pipe sees the lines it saw before; erased before the push prints its result.

import Foundation
import SemelNodeKit

/// Where a push stands, by phase, with the counts this client knows.
///
/// Only what the client can count: files read from its own disk, files whose replies have
/// come back. Where it waits on one reply whose progress it cannot see — the commit, which
/// the server answers once it has checked the whole batch against the locks — the line
/// says that it waits, not how far.
enum PushStatus: Equatable {

    /// Walking and reading the disk. `total` once the walk has listed what it reads, nil
    /// while it lists, or where it matches a wildcard and reads nothing yet.
    case reading(read: Int, total: Int?)

    /// Asking the server what it holds where the push reads: the roots of a folder and
    /// every folder below it, then the children of those whose roots differ from the
    /// disk's. One reply each, which a server busy with another request answers when it
    /// is free.
    case comparing

    /// Sending: `recorded` of `total` files the server has answered for, and the bytes
    /// sent with them. A file the server already held is counted with no bytes, since
    /// none were sent.
    case pushing(recorded: Int, total: Int, bytesSent: Int)

    /// Every file sent; waiting for the server to commit the push's batch, which it
    /// answers in one reply once the lock barrier has judged the whole of it.
    case committing(files: Int)

    /// The phase alone: a change of phase is drawn at once, while a count moving within
    /// one phase waits for the indicator's redraw interval.
    enum Phase: Equatable {
        case reading, comparing, pushing, committing
    }

    var phase: Phase {
        switch self {
        case .reading:    return .reading
        case .comparing:  return .comparing
        case .pushing:    return .pushing
        case .committing: return .committing
        }
    }

    /// The line, without the indicator's erase or any newline.
    var line: String {
        switch self {
        case .reading(_, nil):
            return "Reading files…"
        case .reading(let read, let total?):
            return "Reading \(Self.grouped(read)) of \(Self.grouped(total)) \(Self.files(total))…"
        case .comparing:
            return "Comparing with what the server holds…"
        case .pushing(let recorded, let total, let bytesSent):
            let sent = bytesSent > 0 ? " (\(ByteCount(bytes: bytesSent)) sent)" : ""
            return "Pushing \(Self.grouped(recorded)) of \(Self.grouped(total)) \(Self.files(total))\(sent)…"
        case .committing(let files):
            return "Committing \(Self.grouped(files)) \(Self.files(files)): waiting for the server…"
        }
    }

    private static func grouped(_ value: Int) -> String {
        ProgressLineRenderer.grouped(value)
    }

    private static func files(_ count: Int) -> String {
        count == 1 ? "file" : "files"
    }
}
