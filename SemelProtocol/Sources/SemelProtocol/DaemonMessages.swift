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
    /// When that source is a machine file: the commands outside Semel that write it, each
    /// with the folder it goes in (B-109). `build` pushes what is on disk and nothing else,
    /// so this is what a client says about a file nobody has written yet.
    public let writers: [SourceWriter]

    public init(ports: [String], message: String, missingSource: String? = nil, writers: [SourceWriter] = []) {
        self.ports         = ports
        self.message       = message
        self.missingSource = missingSource
        self.writers       = writers
    }
}

/// A command outside Semel that writes a source — `semel-clang` — and the folder to run it
/// on, relative to the input file system as `missingSource` is: `.` for its root.
public struct SourceWriter: Codable, Equatable, Hashable, Sendable {
    public let command: String
    public let folder:  String

    public init(command: String, folder: String) {
        self.command = command
        self.folder  = folder
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
        case staleIdentity
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
    /// Whether something in the graph selects this namespace's settings — a `ConfigFilter`
    /// with this prefix exists (B-109).
    public let selected: Bool

    public init(namespace: String, toolName: String, descriptors: [ToolDescriptorRecord], selected: Bool = false) {
        self.namespace   = namespace
        self.toolName    = toolName
        self.descriptors = descriptors
        self.selected    = selected
    }
}

/// Why the last settle did what it did to one node (B-91): the node, and upstream of it
/// every node the settle touched on the wires that woke it, each once. Causes point at
/// other nodes by index, so the client draws the tree and nothing it reads is a sentence
/// to take apart.
public struct Explanation: Codable, Equatable, Sendable {
    /// The node asked about first, then the rest in the order the walk reached them —
    /// nearest first, so that what a bound leaves out is what lies furthest away.
    public let nodes: [ExplainedNode]
    /// Nodes the walk reached that a bound left out.
    public let omittedNodes: Int
    /// The bounds the walk had, so a reader told "and 312 more" is told why.
    public let nodeLimit:  Int
    public let depthLimit: Int

    public init(nodes: [ExplainedNode], omittedNodes: Int, nodeLimit: Int, depthLimit: Int) {
        self.nodes        = nodes
        self.omittedNodes = omittedNodes
        self.nodeLimit    = nodeLimit
        self.depthLimit   = depthLimit
    }
}

public struct ExplainedNode: Codable, Equatable, Sendable {

    /// What the node did in the last settle.
    public enum Outcome: String, Codable, Equatable, Sendable {
        /// It ran.
        case computed
        /// It was woken and the cache answered it.
        case fromCache
        /// It was woken and produced nothing: an input was not ready.
        case notRun
        /// It did not run, and its value moved: a pushed file, a folder's manifest.
        case changed
        /// The settle did not reach it.
        case untouched
    }

    /// What a report calls the node — its type, id and path — decided server-side, as
    /// `ErrorRecord.label` is.
    public let label:   String
    public let outcome: Outcome
    /// Whether the settle created it.
    public let isNew:   Bool
    /// The wires whose writes woke it: changed, connected and disconnected ones first, then
    /// by port and wire name.
    public let causes:  [ExplainedCause]
    /// How many more wires woke it than `causes` lists.
    public let unlistedCauses: Int

    public init(label: String, outcome: Outcome, isNew: Bool, causes: [ExplainedCause], unlistedCauses: Int) {
        self.label          = label
        self.outcome        = outcome
        self.isNew          = isNew
        self.causes         = causes
        self.unlistedCauses = unlistedCauses
    }
}

/// One wire that woke a node, and what it brought.
public struct ExplainedCause: Codable, Equatable, Sendable {

    public enum Change: String, Codable, Equatable, Sendable {
        /// The source wrote a value other than the one it held when the settle began.
        case changed
        /// The source wrote the value it already held: the node was woken, and had
        /// nothing new to read on this wire.
        case unchanged
        /// The wire was connected in the settle.
        case connected
        /// The wire was disconnected in the settle.
        case disconnected
    }

    /// The node's input port, and the wire's name on it.
    public let port:        String
    public let wire:        String
    public let change:      Change
    public let sourceLabel: String
    /// Where the source is in `Explanation.nodes`: nil for a source the settle did not
    /// touch — a header a new node was wired to — which the walk does not go into, and for
    /// a source a bound left out.
    public let source:      Int?

    public init(port: String, wire: String, change: Change, sourceLabel: String, source: Int?) {
        self.port        = port
        self.wire        = wire
        self.change      = change
        self.sourceLabel = sourceLabel
        self.source      = source
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
    /// Delete every stored object nothing refers to (B-14). The engine does this itself
    /// as the store grows; the verb is for the reader who wants it now, or wants to see
    /// what it does.
    case collect
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
    /// Why the last settle did what it did to the node at `path`: the nodes upstream of it
    /// that ran or were answered from the cache, and the wires whose values changed on the
    /// way, down to the sources a push changed (B-91). The path is resolved by the client
    /// as `fetch`'s is.
    case explain(fileSystem: FileSystemKind, path: String)
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
    /// What `collect` removed and what it kept, in objects and bytes.
    case collected(removed: Int, removedBytes: Int, kept: Int)
    case tools(namespaces: [ToolNamespaceRecord])
    /// Where the graph the reset discarded was copied to, so the state that made the reset
    /// necessary can still be read. Absent when there was nothing to discard, and when the
    /// server holds its graph in memory and has no file to copy.
    case reset(archivedGraphPath: String?)
    /// Nil when the server has settled nothing since it started: the record is kept in
    /// memory, for the last settle only, and a restart forgets it (B-91).
    ///
    /// In the JSON section rather than the body, unlike `check` and `debug`: their size
    /// follows the graph's, and this one's follows the explanation's own bounds — forty
    /// nodes of ten causes each is tens of kilobytes.
    case explain(explanation: Explanation?)
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
    /// Where the current settle stands, sent as the engine's pass changes state: after a
    /// round of scheduling starts nodes and after a result is written (B-95). Never from
    /// a pass that started nothing, as `settled` says nothing for one. The last of a
    /// settle has `running` empty and `pending` zero; `settled` follows it with the same
    /// three totals and the error count.
    case progress(record: ProgressRecord)
}

/// Where a settle stands, in the settle's own running totals rather than a batch's: the
/// three counts are the ones `settled` will end with, read from the same tally, so a node
/// that ran twice is one node here as it is there.
public struct ProgressRecord: Codable, Equatable, Sendable {
    /// Nodes this settle has fetched as scheduled, once each.
    public let scheduled: Int
    /// Of those, the ones whose latest result was one they ran themselves.
    public let computed: Int
    /// Of those, the ones whose latest result came from a cache entry.
    public let fromCache: Int
    /// Scheduled and not started: the queue ahead, which rises while the cascade is still
    /// generating work and falls as it drains.
    public let pending: Int
    /// Started and not finished, in start order. Carried on every record so that a
    /// renderer showing the active nodes needs nothing more on the wire.
    public let running: [ActiveNode]

    public init(scheduled: Int, computed: Int, fromCache: Int, pending: Int, running: [ActiveNode]) {
        self.scheduled = scheduled
        self.computed  = computed
        self.fromCache = fromCache
        self.pending   = pending
        self.running   = running
    }
}

/// One node computing now: its type and the name a report would give it — its path when
/// it has one, the project file when it is a builder, empty otherwise.
public struct ActiveNode: Codable, Equatable, Sendable {
    public let type: String
    public let name: String

    public init(type: String, name: String) {
        self.type = type
        self.name = name
    }
}
