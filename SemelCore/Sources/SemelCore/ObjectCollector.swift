// ObjectCollector.swift
// SemelCore
//
// The object store's collector (B-14). The store is content-addressed and, until this,
// append-only: every collector the engine had — cache-entry trimming, unreferenced nodes,
// a reset — removed rows and left their objects, and since B-26 every edit interns a fresh
// content-root document per ancestor folder. A mark from what the graph refers to, then a
// sweep of what it does not.
//
// The roots are wherever a hash is written down: a port's value or error message, a cached
// build's outputs, an artifact snapshot — in the live graph and in every graph `reset`
// copied aside, which still refers to its objects and is kept readable on purpose. Two
// kinds of stored document name other objects and are read through: a tree manifest names
// its files, and a folder's content-root document names its children.

import Foundation
import GRDB
import SemelDatabaseModels
import SemelNodeKit

/// What one collection did.
public struct ObjectCollection: Equatable {
    public let removed: Int
    public let removedBytes: Int
    public let kept: Int

    public init(removed: Int, removedBytes: Int, kept: Int) {
        self.removed = removed
        self.removedBytes = removedBytes
        self.kept = kept
    }
}

extension BuildEngine {

    /// How much the store has to grow before the loop collects again at idle. Below it a
    /// settle costs no walk of the store; above it the walk is a small fraction of what
    /// was just written. The first idle after launch collects whatever an earlier run
    /// left, threshold or not.
    public static let collectionThresholdBytes = 64 * 1_048_576

    /// An object younger than this is never collected, referenced or not. An object is
    /// interned before the row that refers to it is written, and a collection that took
    /// its snapshot between the two would otherwise delete it; a minute is far beyond the
    /// loop's write latency, and an object interned again is made young again (`touch`).
    public static let collectionAgeMargin: TimeInterval = 60

    /// Runs at idle when the store has grown enough since the last collection, and once
    /// at the first idle after launch. Best effort, like every idle-time report: a failure
    /// loses one collection, and the next settle gets another.
    func collectObjectsIfDue() {
        let stored = DataObjectStore.shared.bytesStored
        guard let since = bytesStoredAtLastCollection else {
            return collectNow(storedBefore: stored)
        }
        guard stored - since >= Self.collectionThresholdBytes else {
            return
        }
        collectNow(storedBefore: stored)
    }

    private func collectNow(storedBefore stored: Int) {
        bytesStoredAtLastCollection = stored
        guard let collection = FatalErrors.attempt({ try collectUnreferencedObjects() }) else {
            return
        }
        if collection.removed > 0 {
            Self.notice("Collected \(collection.removed) unreferenced object\(collection.removed == 1 ? "" : "s") "
                      + "(\(Self.megabytes(collection.removedBytes)) MB); \(collection.kept) kept.")
        }
    }

    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }

    /// Removes every object nothing refers to and that is older than `margin`. Returns
    /// what it removed and what it kept.
    public func collectUnreferencedObjects(olderThan margin: TimeInterval = collectionAgeMargin) throws -> ObjectCollection {
        let cutoff = Date().addingTimeInterval(-margin)
        let store = DataObjectStore.shared

        var marked = try referencedObjects()
        try markDocuments(reaching: &marked, in: store)

        var removed = 0
        var removedBytes = 0
        var kept = 0
        for object in store.objects() {
            guard !marked.contains(object.hash), object.modificationDate < cutoff else {
                kept += 1
                continue
            }
            try store.remove(hash: object.hash)
            removed += 1
            removedBytes += object.size
        }
        return ObjectCollection(removed: removed, removedBytes: removedBytes, kept: kept)
    }

    // MARK: - Roots

    /// Every hash a row of the live graph, or of an archived one, writes down.
    private func referencedObjects() throws -> Set<DataObjectHash> {
        var marked = Set<DataObjectHash>()
        marked.formUnion(try database.outputPort.selectAllHashes())
        marked.formUnion(try database.artifactSnapshot.selectAll().map(\.contentHash))
        for content in try database.cacheEntry.selectAllContent() {
            marked.formUnion(Self.objects(inCacheContent: content))
        }
        for archive in archivedGraphs() {
            marked.formUnion(Self.referencedObjects(inArchivedGraphAt: archive))
        }
        marked.remove("")
        return marked
    }

    /// The outputs a cached build refers to. An entry this Semel cannot decode refers to
    /// nothing it can name — `Cache` treats such a row as a slot nothing can use.
    static func objects(inCacheContent content: Data) -> [DataObjectHash] {
        guard let entry = try? JSONDecoder().decode(ProcessCacheEntry.self, from: content) else {
            return []
        }
        return entry.outputValues.sorted { $0.key < $1.key }.compactMap { _, value in
            switch value {
            case .value(let hash):
                return hash
            case .noValue(.error(let messageHash)):
                return messageHash
            case .noValue:
                return nil
            }
        }
    }

    /// The graphs `reset` copied aside, beside the live one: `<graph>.broken-<timestamp>`.
    /// Kept readable by keeping their objects; a copy nobody wants is theirs to delete,
    /// as the reset said.
    private func archivedGraphs() -> [String] {
        guard let filePath = database.filePath else {
            return []
        }
        let folder = (filePath as NSString).deletingLastPathComponent
        let prefix = (filePath as NSString).lastPathComponent + ".broken-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasPrefix(prefix) && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }
            .sorted()
            .map { (folder as NSString).appendingPathComponent($0) }
    }

    /// The same three tables of an archived graph, read as SQL against a file whose
    /// schema may be older than this Semel's: a table that is not there contributes
    /// nothing, and a file that cannot be opened is said so, once per collection.
    ///
    /// Read-only first; a copy of a WAL database cannot be opened read-only until its
    /// side files exist, so the second attempt is an ordinary open, which creates them
    /// beside the archive and changes nothing in it.
    static func referencedObjects(inArchivedGraphAt path: String) -> Set<DataObjectHash> {
        var readOnly = GRDB.Configuration()
        readOnly.readonly = true
        guard let queue = (try? DatabaseQueue(path: path, configuration: readOnly)) ?? (try? DatabaseQueue(path: path)) else {
            notice("The archived graph \(path) could not be read; the objects it refers to are not kept for it.")
            return []
        }
        var marked = Set<DataObjectHash>()
        try? queue.read { db in
            if let hashes = try? String.fetchAll(db, sql: "SELECT DISTINCT dataObjectHash FROM OutputPort WHERE dataObjectHash IS NOT NULL") {
                marked.formUnion(hashes)
            }
            if let hashes = try? String.fetchAll(db, sql: "SELECT contentHash FROM ArtifactSnapshot") {
                marked.formUnion(hashes)
            }
            if let contents = try? Data.fetchAll(db, sql: "SELECT content FROM CacheEntry") {
                for content in contents {
                    marked.formUnion(objects(inCacheContent: content))
                }
            }
        }
        return marked
    }

    // MARK: - Documents that name other objects

    /// Follows the two document kinds from every marked object until nothing new is
    /// reached. Each object is looked at once, by its first bytes: a content-root document
    /// opens with its format tag, a tree manifest with the kind its JSON is tagged with;
    /// anything else is a file, and files name nothing.
    private func markDocuments(reaching marked: inout Set<DataObjectHash>, in store: DataObjectStore) throws {
        var pending = marked.sorted()
        var inspected = Set<DataObjectHash>()
        while let hash = pending.popLast() {
            guard inspected.insert(hash).inserted else {
                continue
            }
            for referenced in Self.objects(namedByDocument: hash, in: store) where marked.insert(referenced).inserted {
                pending.append(referenced)
            }
        }
    }

    private static let contentRootTag = Data(FolderContentRoot.formatTag.utf8)
    private static let treeManifestTag = Data("{\"kind\":\(TreeManifest.kind),".utf8)

    /// A tree manifest as its JSON is written: the kind and the object, keys sorted.
    private struct TreeDocument: Decodable {
        let object: TreeManifest
    }

    static func objects(namedByDocument hash: DataObjectHash, in store: DataObjectStore) -> [DataObjectHash] {
        let longest = max(contentRootTag.count, treeManifestTag.count)
        guard let head = store.prefix(ofHash: hash, count: longest) else {
            return []
        }
        if head.starts(with: contentRootTag) {
            guard let bytes = try? store.read(hash: hash) else {
                return []
            }
            return objects(inContentRootDocument: String(decoding: bytes, as: UTF8.self))
        }
        if head.starts(with: treeManifestTag) {
            guard let bytes = try? store.read(hash: hash),
                  let document = try? JSONDecoder().decode(TreeDocument.self, from: Data(bytes)) else {
                return []
            }
            return document.object.entries.map(\.hash)
        }
        return []
    }

    /// The children a content-root document names by hash: the second field of each line
    /// after the tag, `hash <h>` for a file's bytes or a subfolder's own document.
    static func objects(inContentRootDocument text: String) -> [DataObjectHash] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 2, fields[1].hasPrefix("hash ") else {
                return nil
            }
            return String(fields[1].dropFirst("hash ".count))
        }
    }
}
