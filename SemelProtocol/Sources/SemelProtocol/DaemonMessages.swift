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

public enum FileSystemKind: String, Codable, Equatable, Sendable {
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
    /// How many nodes downstream of this one fail only because this one did. A cascade is
    /// sent as its cause plus this count, not as a record per node that carries it: one
    /// deleted header stops every node that reads it, and the header is what can be fixed.
    public let downstreamCarrierCount: Int

    public init(label: String, entries: [ErrorEntry], downstreamCarrierCount: Int = 0) {
        self.label                  = label
        self.entries                = entries
        self.downstreamCarrierCount = downstreamCarrierCount
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

public struct ToolNamespaceRecord: Codable, Equatable, Sendable {
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
    case list(fileSystem: FileSystemKind, pattern: String)
    case beginBatch
    case endBatch
    /// The file's bytes travel in the frame body. No hash: hashing lives in SemelNodeKit,
    /// which this package does not link, so the server interns and hashes the bytes itself.
    case pushFile(path: String, mode: UInt16)
    case pushFolder(path: String)
    case remove(pattern: String)
    case fetch(fileSystem: FileSystemKind, path: String)
    case errors
    case tools
    /// Discards the derived graph and rebuilds it from what was pushed. `clearCache` also
    /// discards the cached builds, which the rebuild would otherwise be served from: the
    /// cache is keyed on the inputs and not on the graph, so keeping it makes a reset a
    /// pass of lookups rather than a cold build of every project in the home.
    case reset(clearCache: Bool)
    case nudge
    /// Blocks until the graph has settled: every scheduled node processed and nothing
    /// asking for another pass. The reply is `.ok`. What a script needs between a push
    /// and a report, since every other request returns while the build runs behind it.
    case wait
    case debug
    case subscribe
}

// MARK: - Responses

public enum DaemonResponse: Codable, Equatable, Sendable {
    case ok
    case list(entries: [ListEntry])
    case pushFile(didChange: Bool)
    /// What the removal took, split by kind: a client reports the two differently, and a
    /// pattern that took every file of a folder and left the folder standing is a correct
    /// outcome that reads as a no-op unless it is said.
    case remove(removedFiles: [String], removedFolders: [String])
    /// The file's bytes travel in the frame body.
    case fetch(mode: UInt16)
    case errors(records: [ErrorRecord])
    case tools(namespaces: [ToolNamespaceRecord])
    /// Where the graph the reset discarded was copied to, so the state that made the reset
    /// necessary can still be read. Absent when the server holds its graph in memory and
    /// has no file to copy.
    case reset(archivedGraphPath: String?)
    /// The description of the graph travels in the frame body, as UTF-8. A few hundred
    /// nodes describe themselves in more than the megabyte the JSON section allows, and
    /// that cap is not a number to raise: a declared JSON length is checked before the
    /// bytes are read, so it bounds what a header alone can ask this process to allocate.
    /// The body's own limit is three orders of magnitude higher for exactly this traffic.
    case debug
}

// MARK: - Events

/// What the engine reports from its background task, carried to every subscribed
/// connection. B-50's settle diffs become a third case.
public enum DaemonEvent: Codable, Equatable, Sendable {
    case errors(records: [ErrorRecord])
    case notice(line: String)
}
