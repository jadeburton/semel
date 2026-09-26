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

/// What `ls` prints beside a name: one case per state the graph can be in about it, so
/// that a reader can tell the ones apart that call for different things.
///
/// `deleted` and `unreferenced` are the engine's "ghost" entries — referenced but taken
/// away, or the reverse — and hiding them would be a behavior change.
public enum EntryStatus: String, Codable, Equatable, Sendable {
    /// The name stands for something that is there.
    case none
    /// Nothing in the graph reads this node, and nothing it holds keeps it: a name the
    /// collector will take away.
    case unreferenced
    /// A value is on its way.
    case pending
    /// Nothing has produced a value here: a source nobody pushed, or a product whose input
    /// has none. Not a failure — a fresh graph is full of this — and nothing to wait on.
    case notProduced
    /// A source the user removed. It stands until the collector reaches it, and it settles
    /// by itself.
    case deleted
    /// A product whose build failed, or whose input carries a failure from above it. The
    /// one of these states that is a failure to act on.
    case failed
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
    /// When the message says a source has not been pushed: that source, as `push` takes
    /// it — relative to the input file system, a folder ending in `/`. What lets a client
    /// act on the path instead of recognising the sentence (B-110).
    public let missingSource: String?

    public init(ports: [String], message: String, missingSource: String? = nil) {
        self.ports         = ports
        self.message       = message
        self.missingSource = missingSource
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
    /// How many nodes the record stands for: one, or the several of one type that carry
    /// one report and are named together in the label (B-110).
    public let nodeCount: Int

    public init(label: String, entries: [ErrorEntry], downstreamCarrierCount: Int = 0, nodeCount: Int = 1) {
        self.label                  = label
        self.entries                = entries
        self.downstreamCarrierCount = downstreamCarrierCount
        self.nodeCount              = nodeCount
    }
}

/// One invariant of the graph that does not hold. `check` answers a list of these; nothing
/// repairs anything.
///
/// The sentence is written for a person and the kind is what a reader classifies by, so a
/// client never has to read the text to decide what it is looking at.
public struct CheckFinding: Codable, Equatable, Sendable {

    public enum Kind: String, Codable, Equatable, Sendable {
        case danglingWire
        case missingOutputPort
        case unreadableGraphSpec
        case unlinkedNodeType
        case productWithNoProducer
        case missingManifestChild
        case errorWithoutMessage
        case unreadableCacheKey
        case graphCouldNotBeRead
    }

    public let kind:     Kind
    /// The node or the wire the finding concerns, named so it can be found again.
    public let subject:  String
    public let sentence: String

    public init(kind: Kind, subject: String, sentence: String) {
        self.kind     = kind
        self.subject  = subject
        self.sentence = sentence
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
    /// Walks the graph and answers every invariant that does not hold. Repairs nothing:
    /// `reset` is the repair, and this is how one learns whether it is needed.
    ///
    /// Meant for a settled graph, and `wait` is what settles one. The walk happens inside
    /// a single read, so it cannot see half of a change — but a node whose wires the engine
    /// is still building has no wires yet, and looks exactly like a node whose wires are
    /// missing. The reply carries how many nodes were scheduled so a client can say which
    /// graph it asked; the server neither waits nor refuses.
    case check
    /// The installed tools with their machine settings for `platform` (a `Platform`'s raw
    /// value): the SDK is one per platform (B-109).
    case tools(platform: String)
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
    /// With no key, the whole graph as text. With one, that cache entry's key material —
    /// the text its key is the hash of, which is what makes two builds that disagreed a
    /// diff rather than two hashes. Either answer travels in the reply's body.
    case debug(cacheKey: String?)
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
    /// The findings travel in the frame body, as a JSON array of `CheckFinding`, for the
    /// reason `debug`'s text does: one broken invariant per node is the shape a badly
    /// broken graph has, and a reply over the JSON section's megabyte is refused outright —
    /// which would leave the one command meant for a graph in that state unable to answer
    /// about it. The body's limit is three orders of magnitude higher. Records rather than
    /// rendered lines, so the client still does the formatting and still classifies by
    /// `kind` rather than by what a sentence happens to say.
    ///
    /// `scheduledNodes` is how many nodes the walk found still scheduled, counted from the
    /// same read as the findings. It stays here in the JSON rather than joining them in
    /// the body: it is one integer, and it is what tells a reader whether a finding about
    /// wiring describes a defect or work in flight.
    case check(scheduledNodes: Int)
    case tools(namespaces: [ToolNamespaceRecord])
    /// Where the graph the reset discarded was copied to, so the state that made the reset
    /// necessary can still be read. Absent when there was nothing to discard, and when the
    /// server holds its graph in memory and has no file to copy.
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
/// connection.
public enum DaemonEvent: Codable, Equatable, Sendable {
    case errors(records: [ErrorRecord])
    case notice(line: String)
    /// The totals for one settle: how many nodes the engine fetched as scheduled, how
    /// many of them ran, how many were answered out of the cache, and how many errors the
    /// error report that precedes this event named. A cache hit and a full recompute are
    /// otherwise indistinguishable at the prompt, which is the whole point of carrying
    /// this over the protocol rather than leaving it in the server's debug log.
    ///
    /// `scheduled` is not `computed + fromCache`: a node fetched as scheduled whose
    /// inputs are not yet satisfied is unscheduled again without producing either.
    case settled(scheduled: Int, computed: Int, fromCache: Int, errors: Int)
    /// What the settle did to the products, as the difference between this settle and the
    /// last: paths that gained a value nothing had reported, paths whose bytes are not
    /// the ones last reported, and paths whose node was collected. Delivered after
    /// `settled` for the same settle.
    ///
    /// Three lists rather than a list of (path, kind) pairs: every reader groups by kind
    /// to say anything about them, and a client classifies by which list a path arrived
    /// in rather than by a word. A product that failed is in none of them — that belongs
    /// to `errors`, and saying it twice in two vocabularies is what this event exists to
    /// stop.
    case artifacts(appeared: [String], changed: [String], disappeared: [String])
}
