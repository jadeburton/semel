// BatchJournal.swift
// SemelCore
//
// What a batch changed in `input:`, path by path, as it was before the batch: the record
// that makes a batch all or nothing (B-146). A push lands in `input:` as it arrives, as it
// always has; the journal is what lets the outermost `commit` take the whole batch back
// when the lock barrier refuses it (`LockBarrier`), and what a `restore` goes through like
// any other batch.

import Foundation
import SemelDatabaseModels
import SemelNodeKit

/// One output port's row as the journal keeps it: its kind of value and the object it
/// names. Written back as the same row, so a restored port compares equal to the row it
/// held before the batch and wakes nothing.
public struct JournaledPort: Codable, Equatable {
    public let valueKind:      UInt8
    public let dataObjectHash: String?

    init(_ port: OutputPort) {
        valueKind      = port.valueKind.rawValue
        dataObjectHash = port.dataObjectHash
    }

    func outputPort(nodeID: ObjectID, portSymbolID: ObjectID) throws -> OutputPort {
        guard let valueKind = OutputPort.ValueKind(rawValue: valueKind) else {
            throw BatchJournalError.unreadableRecord(path: "", reason: "a port row of kind \(valueKind)")
        }
        return OutputPort(nodeID: nodeID, nameSymbolID: portSymbolID, valueKind: valueKind,
                          dataObjectHash: dataObjectHash)
    }
}

/// What one path of `input:` held before the batch first changed it.
///
/// The shape of a `TreeManifestEntry` — a file, a folder, or nothing — but holding each
/// node's own rows rather than a hash and a mode. A tree entry says what a file *is*; a
/// rejected batch has to put back what the graph *had*, and that includes the states a
/// tree has no word for: a name a formula asked for and nobody pushed, a source removed
/// and still wired, a folder nobody pinned. A file's two rows carry its bytes, its mode and
/// its link target between them; a folder's two carry its pin and its link.
public enum JournalRecord: Codable, Equatable {
    /// No node stood at the path.
    case absent
    case file(content: JournaledPort?, metadata: JournaledPort?)
    case folder(pinned: JournaledPort?, symbolicLink: JournaledPort?)

    /// Whether the path held something a push leaves: a file with its bytes, or a pinned
    /// folder. What a rejection lists when it says which paths moved a root.
    var holdsContent: Bool {
        switch self {
        case .absent:
            return false
        case .file(let content, _):
            return content?.valueKind == OutputPort.ValueKind.value.rawValue
        case .folder(let pinned, _):
            return pinned?.valueKind == OutputPort.ValueKind.value.rawValue
        }
    }
}

public enum BatchJournalError: Error, Equatable, CustomStringConvertible {
    /// A node of a kind `input:` does not hold, met where the journal records.
    case unexpectedKind(path: String, kind: UInt)
    /// A record the journal wrote and cannot read back.
    case unreadableRecord(path: String, reason: String)
    /// A path the replay cannot put back as it was, and why.
    case cannotRestore(path: String, reason: String)

    public var description: String {
        switch self {
        case .unexpectedKind(let path, let kind):
            return "input:/\(path) is a node of kind \(kind), which the input file system does not hold"
        case .unreadableRecord(let path, let reason):
            return "the batch's record of input:/\(path) cannot be read: \(reason)"
        case .cannotRestore(let path, let reason):
            return "input:/\(path) cannot be put back as it was before the batch: \(reason)"
        }
    }
}

/// The record of one open batch: for each path the batch touches, what was there before.
///
/// Rows in the graph's own `Metadata` table, written in the same transaction as the change
/// they precede — a push of a batch of files records its files and their journal together
/// (`DatabaseLayer.withTransactionPerStep`) — so the journal and the tree it describes
/// cannot disagree. The first record of a path wins: a path pushed twice in a batch is
/// journaled once, with what it held before the batch.
///
/// A class, because a session holds one open across many requests and every push in the
/// batch adds to it; the set of paths already recorded is kept beside the rows so that a
/// path is read from the graph once per batch, not once per push of it.
public final class BatchJournal {

    /// Where the rows live: `batchJournal/<identifier>/<path>`.
    static let keyPrefix = "batchJournal/"

    public let identifier: String
    private var recorded: Set<Path> = []

    private var database: DatabaseLayer {
        DatabaseLayer.shared
    }

    private var rowPrefix: String {
        "\(Self.keyPrefix)\(identifier)/"
    }

    /// Opens a journal with no record. Rows a previous process left under the same
    /// identifier belong to a batch that never reached its `commit` and are dropped.
    public init(identifier: String) throws {
        self.identifier = identifier
        try database.metadata.deleteAll(withExactPrefix: rowPrefix)
    }

    /// Drops every journal row in the graph: what a server starting up does, since no
    /// session of the process before it can commit or reject its batch any more.
    public static func discardAll() throws {
        try DatabaseLayer.shared.metadata.deleteAll(withExactPrefix: keyPrefix)
    }

    /// The paths recorded so far, in path order.
    public var paths: [Path] {
        recorded.sorted { $0.string.utf8.lexicographicallyPrecedes($1.string.utf8) }
    }

    // MARK: - Recording

    /// The symbol ids of the four ports a record reads.
    private struct Ports {
        let content      = StaticFile.outputPort.asSymbolID()
        let metadata     = StaticFile.fileMetadataOutputPort.asSymbolID()
        let pinned       = Folder.pinnedOutputPort.asSymbolID()
        let symbolicLink = Folder.symbolicLinkOutputPort.asSymbolID()

        var all: [ObjectID] { [content, metadata, pinned, symbolicLink] }
    }

    /// Records `path` — relative to `input:` — and every folder on the way to it, each as
    /// it is now, unless already recorded in this batch. Called before a push, a link push
    /// or a folder push writes: whatever the push creates on the way is on record as
    /// absent, so a replay takes it away again.
    ///
    /// One query for the whole path (`selectPath`), the one a push resolves its folders
    /// with, so a push into a tree already recorded reads nothing and a push into a new
    /// one reads once.
    public func recordPathAndFoldersAbove(_ path: Path) throws {
        let names = path.segments
        guard !names.isEmpty else {
            return
        }
        let prefixes = (1...names.count).map { Path(segments: Array(names.prefix($0))) }
        guard prefixes.contains(where: { !recorded.contains($0) }) else {
            return
        }
        let ports  = Ports()
        let rootID = try Folder.inputFileSystem.requireID()
        let steps  = try database.node.selectPath(below: rootID, names: names, portSymbolIDs: ports.all)
        for (index, prefix) in prefixes.enumerated() where !recorded.contains(prefix) {
            let step = steps.first { $0.depth == index + 1 }
            try record(step.map { try Self.record(of: $0.node.kind, ports: $0.ports, at: prefix) } ?? .absent,
                       at: prefix)
        }
    }

    /// Records `path`, the folders on the way to it, and — when it is a folder — every
    /// file and folder below it: what a removal is about to take.
    public func recordSubtree(at path: Path) throws {
        try recordPathAndFoldersAbove(path)
        guard let node = try Folder.inputFileSystem.childNode(path: path), node.kind == Folder.kind else {
            return
        }
        let ports = Ports()
        let rows  = try database.node.selectSubtree(below: try node.requireID(), kind: Folder.kind,
                                                    portSymbolIDs: [ports.pinned, ports.symbolicLink])
        var pathByID: [ObjectID: Path] = [:]
        for row in rows {
            guard row.depth > 0 else {
                pathByID[row.id] = path
                continue
            }
            guard let parentNodeID = row.parentNodeID, let parentPath = pathByID[parentNodeID], let name = row.name else {
                continue
            }
            let folderPath = parentPath / name
            pathByID[row.id] = folderPath
            if !recorded.contains(folderPath) {
                try record(Self.record(of: Folder.kind, ports: row.ports, at: folderPath), at: folderPath)
            }
        }
        for (folderID, folderPath) in pathByID.sorted(by: { $0.value.string < $1.value.string }) {
            try recordFiles(in: folderID, at: folderPath, ports: ports)
        }
    }

    /// The files directly in one folder, a query per port whatever their number.
    private func recordFiles(in folderID: ObjectID, at folderPath: Path, ports: Ports) throws {
        let files = try database.node.selectChildSummaries(parentNodeID: folderID).filter { $0.kind == StaticFile.kind }
        guard !files.isEmpty else {
            return
        }
        let contents  = try database.node.selectChildPorts(parentNodeID: folderID, nameSymbolID: ports.content)
        let metadatas = try database.node.selectChildPorts(parentNodeID: folderID, nameSymbolID: ports.metadata)
        for file in files {
            let filePath = folderPath / (try file.requireName())
            guard !recorded.contains(filePath) else {
                continue
            }
            try record(.file(content: contents[file.id].map(JournaledPort.init),
                             metadata: metadatas[file.id].map(JournaledPort.init)), at: filePath)
        }
    }

    private static func record(of kind: UInt, ports: [ObjectID: OutputPort], at path: Path) throws -> JournalRecord {
        let symbols = Ports()
        switch kind {
        case StaticFile.kind:
            return .file(content: ports[symbols.content].map(JournaledPort.init),
                         metadata: ports[symbols.metadata].map(JournaledPort.init))
        case Folder.kind:
            return .folder(pinned: ports[symbols.pinned].map(JournaledPort.init),
                           symbolicLink: ports[symbols.symbolicLink].map(JournaledPort.init))
        default:
            throw BatchJournalError.unexpectedKind(path: path.string, kind: kind)
        }
    }

    private func record(_ journalRecord: JournalRecord, at path: Path) throws {
        let text = String(decoding: try JSONEncoder().encode(journalRecord), as: UTF8.self)
        try database.metadata.insertIfAbsent(key: rowPrefix + path.string, value: text)
        recorded.insert(path)
    }

    /// Reads the set of recorded paths back from the rows: after a step that recorded and
    /// then threw out of its transaction, whose rows went with it, so a later push of the
    /// same path in the batch records it again.
    public func reloadRecordedPaths() throws {
        recorded = Set(try records().keys)
    }

    // MARK: - Reading back

    /// Every record, by path.
    public func records() throws -> [Path: JournalRecord] {
        var result: [Path: JournalRecord] = [:]
        for row in try database.metadata.selectEntries(withExactPrefix: rowPrefix) {
            let path = Path(String(row.key.dropFirst(rowPrefix.count)))
            do {
                result[path] = try JSONDecoder().decode(JournalRecord.self, from: Data(row.value.utf8))
            } catch {
                throw BatchJournalError.unreadableRecord(path: path.string, reason: "\(error)")
            }
        }
        return result
    }

    /// What `path` holds now, in the shape of a record: what a rejection compares with the
    /// record to say which paths the batch really changed.
    public static func currentRecord(at path: Path) throws -> JournalRecord {
        guard let node = try Folder.inputFileSystem.childNode(path: path) else {
            return .absent
        }
        let ports  = Ports()
        let nodeID = try node.requireID()
        var rows: [ObjectID: OutputPort] = [:]
        for symbolID in ports.all {
            rows[symbolID] = try DatabaseLayer.shared.outputPort.select(nodeID: nodeID, nameSymbolID: symbolID)
        }
        return try record(of: node.kind, ports: rows, at: path)
    }

    /// Closes the journal: its rows go, and the batch stands as it is.
    public func close() throws {
        try database.metadata.deleteAll(withExactPrefix: rowPrefix)
        recorded.removeAll()
    }

    // MARK: - Replaying

    /// Puts every recorded path back as it was before the batch, in one transaction, and
    /// closes the journal: `input:` is then what it was before `beginBatch`.
    ///
    /// Two passes. What the batch made where nothing stood goes first, deepest path first,
    /// so a folder the batch made is empty when its turn comes. Then what stood before is
    /// written back, shallowest first, so a folder is there before the files in it. Each
    /// port is written as the row it was, and `writeToOutputPort` writes nothing for a row
    /// already equal, so a path the batch pushed unchanged costs a comparison.
    ///
    /// What the batch's writes woke below `input:` is not unwound here: a consumer the
    /// batch scheduled stays scheduled, and its next run reads the values it read before
    /// the batch and is answered from the cache.
    public func replay() throws {
        try database.withTransaction {
            let records = try records()
            let deepestFirst = records.keys.sorted { ($0.count, $1.string) > ($1.count, $0.string) }
            for path in deepestFirst where records[path] == .absent {
                try removeWhatTheBatchMade(at: path)
            }
            for path in deepestFirst.reversed() {
                switch records[path] {
                case .file(let content, let metadata)?:
                    try restoreFile(at: path, content: content, metadata: metadata)
                case .folder(let pinned, let symbolicLink)?:
                    try restoreFolder(at: path, pinned: pinned, symbolicLink: symbolicLink)
                case .absent?, nil:
                    continue
                }
            }
            try close()
        }
    }

    /// Takes away what the batch made at a path where nothing stood. A node nothing is
    /// wired to and with nothing below it goes; one a settle wired a consumer to while the
    /// batch was open stays, as the name a consumer asks for and nobody pushed — the state
    /// such a name holds when nothing was ever pushed there.
    private func removeWhatTheBatchMade(at path: Path) throws {
        guard let nodeRecord = try Folder.inputFileSystem.childNode(path: path) else {
            return
        }
        let node = try nodeRecord.makeNode()
        let isLoose = try node.hasNoOutputWires() && node.hasNoInputWires() && nodeRecord.allChildren.isEmpty
        if isLoose {
            try node.delete()
            return
        }
        switch node {
        case let file as StaticFile:
            if try nodeRecord.writeToOutputPort(StaticFile.outputPort, value: .noValue(reason: .initializing)) {
                try file.notifyParentOfChildContentChange()
            }
        case let folder as Folder:
            if try nodeRecord.writeToOutputPort(Folder.pinnedOutputPort, value: .noValue(reason: .initializing)) {
                try folder.notifyParentOfChildContentChange()
            }
        default:
            throw BatchJournalError.unexpectedKind(path: path.string, kind: nodeRecord.kind)
        }
    }

    private func restoreFile(at path: Path, content: JournaledPort?, metadata: JournaledPort?) throws {
        let ports    = Ports()
        let fullPath = Path(Folder.inputFileSystemName) / path
        if let existing = try Folder.inputFileSystem.childNode(path: path), existing.kind != StaticFile.kind {
            try removeForReplacement(existing, at: path)
        }
        let parentFolder = try path.deletingLastComponent.map {
            try Folder.inputFileSystem.ensureEntirePathExistsAsFolders($0, pinned: false, forAChild: true)
        } ?? Folder.inputFileSystem
        let specNode = GraphSpecNode(StaticFile.self, properties: [StaticFile.pathProperty: fullPath.string])
        let (found, _) = try specNode.findOrCreateMatchingNode()
        let nodeRecord = try StaticFile.adopt(found, into: parentFolder)
        guard let file = try nodeRecord.nodeAsAny() as? StaticFile else {
            throw NodeError.nameCollision(path: fullPath.string, existingKind: nodeRecord.kind)
        }
        let nodeID = try nodeRecord.requireID()
        var changed = false
        if let metadata {
            changed = try nodeRecord.writeToOutputPort(port: metadata.outputPort(nodeID: nodeID, portSymbolID: ports.metadata))
                || changed
        }
        if let content {
            changed = try nodeRecord.writeToOutputPort(port: content.outputPort(nodeID: nodeID, portSymbolID: ports.content))
                || changed
        }
        if changed {
            try file.notifyParentOfChildContentChange()
        }
        // A file with no value and nothing wired to it is one the collector takes at idle,
        // as a removal leaves it; one with a value is held.
        let collectable = content?.valueKind != OutputPort.ValueKind.value.rawValue
        try database.node.updatePendingDeletion(nodeID: nodeID, pendingDeletion: collectable && file.hasNoOutputWires())
    }

    private func restoreFolder(at path: Path, pinned: JournaledPort?, symbolicLink: JournaledPort?) throws {
        let ports = Ports()
        if let existing = try Folder.inputFileSystem.childNode(path: path), existing.kind != Folder.kind {
            try removeForReplacement(existing, at: path)
        }
        let nodeRecord = try Folder.inputFileSystem.ensureEntirePathExistsAsFolders(path, pinned: false)
        let nodeID     = try nodeRecord.requireID()
        var changed    = false
        if let pinned {
            changed = try nodeRecord.writeToOutputPort(port: pinned.outputPort(nodeID: nodeID, portSymbolID: ports.pinned))
                || changed
        }
        if let symbolicLink {
            changed = try nodeRecord.writeToOutputPort(port: symbolicLink.outputPort(nodeID: nodeID,
                                                                                     portSymbolID: ports.symbolicLink))
                || changed
        }
        if changed {
            try nodeRecord.makeNode().notifyParentOfChildContentChange()
        }
    }

    /// A node of the other kind where the record says a file or a folder stood: the batch
    /// removed one and pushed the other under its name. It goes, which it can when nothing
    /// was wired to it while the batch was open — nothing could be, before the engine ran.
    private func removeForReplacement(_ nodeRecord: NodeRecord, at path: Path) throws {
        let node = try nodeRecord.makeNode()
        guard try node.hasNoOutputWires(), try nodeRecord.allChildren.isEmpty else {
            throw BatchJournalError.cannotRestore(path: path.string,
                                                  reason: "the batch put a \(type(of: node)) there, and something is wired to it")
        }
        try node.delete()
    }
}
