// LockedFolders.swift
// SemelProtocol
//
// The records the lock barrier and the checkpoints send (B-146), mirrored from the engine
// for the reason every record here is: the protocol package does not import it.

import Foundation

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
