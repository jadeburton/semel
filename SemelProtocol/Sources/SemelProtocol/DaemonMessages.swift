// DaemonMessages.swift
// SemelProtocol
//
// The daemon role: a local CLI driving a local build engine. One request per CLI
// operation, structured replies, the client does the formatting. Paths are absolute within
// the named file system and already resolved by the client, so the server never sees `..`.
//
// Every associated value is labeled. Swift's synthesized Codable turns a label into the
// JSON key, so this is what keeps `_0` off the wire; a case that adds a field disturbs
// only its own object.

import Foundation

// MARK: - Shared records

public enum FileSystemName: String, Codable, Equatable, Sendable {
    case input
    case output
}

public enum EntryKind: String, Codable, Equatable, Sendable {
    case file
    case folder
}

/// What `ls` prints beside a name. `missing` and `unreferenced` are the engine's
/// "ghost" entries — referenced but deleted, or the reverse — and hiding them would be a
/// behavior change.
public enum EntryStatus: String, Codable, Equatable, Sendable {
    case none
    case missing
    case unreferenced
    case pending
    case error
}

public struct ListEntry: Codable, Equatable, Sendable {
    public let path:   String
    public let kind:   EntryKind
    public let size:   Int?
    public let mode:   UInt16?
    public let status: EntryStatus

    public init(path: String, kind: EntryKind, size: Int?, mode: UInt16?, status: EntryStatus) {
        self.path   = path
        self.kind   = kind
        self.size   = size
        self.mode   = mode
        self.status = status
    }
}

/// One distinct message a node is carrying, and the ports carrying it. Grouped by message
/// rather than by port because a node that fails usually fails on all of its ports at once
/// with the same reason.
public struct ErrorEntry: Codable, Equatable, Sendable {
    public let ports:   [String]
    public let message: String

    public init(ports: [String], message: String) {
        self.ports   = ports
        self.message = message
    }
}

public struct ErrorRecord: Codable, Equatable, Sendable {
    /// What to call the node in a report: a path if it has one, the project file if it is a
    /// builder, the type name otherwise. Decided server-side, where the graph is.
    public let label:   String
    public let entries: [ErrorEntry]

    public init(label: String, entries: [ErrorEntry]) {
        self.label   = label
        self.entries = entries
    }
}

public struct ToolDescriptorRecord: Codable, Equatable, Sendable {
    public let name:            String
    public let version:         String
    public let platform:        String
    public let architecture:    String
    public let machineSettings: [String: String]

    public init(name: String, version: String, platform: String, architecture: String,
                machineSettings: [String: String]) {
        self.name            = name
        self.version         = version
        self.platform        = platform
        self.architecture    = architecture
        self.machineSettings = machineSettings
    }
}

public struct ToolNamespace: Codable, Equatable, Sendable {
    public let namespace:   String
    public let toolName:    String
    /// Empty when no such tool is installed; the client prints that as a comment.
    public let descriptors: [ToolDescriptorRecord]

    public init(namespace: String, toolName: String, descriptors: [ToolDescriptorRecord]) {
        self.namespace   = namespace
        self.toolName    = toolName
        self.descriptors = descriptors
    }
}

// MARK: - Requests

public enum DaemonRequest: Codable, Equatable, Sendable {
    case list(fileSystem: FileSystemName, pattern: String)
    case beginBatch
    case endBatch
    /// The file's bytes travel in the frame body. No hash: hashing lives in SemelNodeKit,
    /// which this package does not link, so the server interns and hashes the bytes itself.
    case pushFile(path: String, mode: UInt16)
    case pushFolder(path: String)
    case remove(pattern: String)
    case fetch(fileSystem: FileSystemName, path: String)
    case errors
    case tools
    case reset
    case nudge
    case debug
    case subscribe
}

// MARK: - Responses

public enum DaemonResponse: Codable, Equatable, Sendable {
    case ok
    case list(entries: [ListEntry])
    case pushFile(didChange: Bool)
    case remove(removedPaths: [String])
    /// The file's bytes travel in the frame body.
    case fetch(mode: UInt16)
    case errors(records: [ErrorRecord])
    case tools(namespaces: [ToolNamespace])
    case debug(text: String)
}

// MARK: - Events

/// What the engine reports from its background task, carried to every subscribed
/// connection. B-50's settle diffs become a third case.
public enum DaemonEvent: Codable, Equatable, Sendable {
    case errors(records: [ErrorRecord])
    case notice(line: String)
}
