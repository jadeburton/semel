// LockedFolders.swift
// SemelProtocol
//
// The records the lock barrier and the checkpoints send (B-146), mirrored from the engine
// for the reason every record here is: the protocol package does not import it.

import Foundation

/// What a lock in `input:` says about its folder, as far as the barrier could read it.
public enum LockExpectation: Codable, Equatable, Sendable {
    /// The lock records this content root, under this Semel's fold.
    case contentRoot(String)
    /// The lock was folded under another format, `fold`, so its root cannot be compared:
    /// the folder may hold exactly what was vendored.
    case otherFold(fold: String, contentRoot: String)
    /// The lock's text is not a lock. `line` is the line that says so, when one does — a
    /// lock with no `content` line has none — and `problem` is what is wrong with it.
    case unreadable(line: Int?, problem: String)
}

/// One checkpoint: a name and the content root it names. No moment: a checkpoint is a
/// value, and two of one tree are one root whenever they were taken.
public struct CheckpointRecord: Codable, Equatable, Sendable {
    public let name: String
    public let contentRoot: String

    public init(name: String, contentRoot: String) {
        self.name        = name
        self.contentRoot = contentRoot
    }
}
