// DataObjectStore.swift
// semel
//
// Content-addressed filesystem store for DataObject bytes.
//
// All DataObject content lives here, on disk, keyed by SHA-256 hash.
// The database tracks *which* hashes exist, but never holds the bytes.
// This means projecting a file into a build sandbox is a single APFS
// copy-on-write clone (essentially free) rather than an extract-from-DB
// + write cycle.
//
// Store layout:
//   ~/Library/Application Support/semel/objects/<xx>/<sha256hash>
//
// The two-character prefix shard (`<xx>`) avoids single-directory inode
// limits when thousands of objects accumulate — the same technique used
// by Git's object store.

import Foundation
import SemelDatabaseModels
import CryptoKit

// MARK: - DataObjectStore

/// The canonical on-disk store for all DataObject content.
///
/// Content is immutable once written: a given hash always maps to the same
/// bytes, so entries are written once and never modified.  Files are marked
/// read-only (0o444) after being stored to enforce this invariant.
public final class DataObjectStore {

    /// The process-wide store.  Every `intern()` goes through it, so it is a global
    /// rather than something threaded through each call site — but it is swappable, so
    /// a test can point the whole process at a private store instead of the user's.
    public static var shared = DataObjectStore()

    private let storeRoot: URL

    convenience init() {
        self.init(storeRoot: SemelPaths.objectStore)
    }

    public init(storeRoot: URL) {
        self.storeRoot = storeRoot
        // Best-effort: `store(hash:content:)` creates the shard directory with
        // intermediates anyway, so a failure here is not fatal.
        try? FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    /// Canonical on-disk URL for the object with the given hash.
    public func objectURL(hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        return storeRoot
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(hash)
    }

    // MARK: - Existence check

    public func exists(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: objectURL(hash: hash).path)
    }

    // MARK: - What the collector reads (B-14)

    /// One object as the collector sees it: its name, its size, and when it was last
    /// stored — which is also when it was last *re*-stored, see `touch`.
    public struct StoredObject: Equatable {
        public let hash: String
        public let size: Int
        public let modificationDate: Date
    }

    /// Every object in the store, by hash, with size and age. Walks the shards; a name
    /// starting with a dot is bytes on their way in (`temporaryURL`) and not an object.
    public func objects() -> [StoredObject] {
        let fileManager = FileManager.default
        var objects: [StoredObject] = []
        guard let shards = try? fileManager.contentsOfDirectory(atPath: storeRoot.path) else {
            return []
        }
        for shard in shards.sorted() {
            let shardURL = storeRoot.appendingPathComponent(shard, isDirectory: true)
            guard let names = try? fileManager.contentsOfDirectory(atPath: shardURL.path) else {
                continue
            }
            for name in names.sorted() where !name.hasPrefix(".") {
                let values = try? shardURL.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                objects.append(StoredObject(hash: name,
                                            size: values?.fileSize ?? 0,
                                            modificationDate: values?.contentModificationDate ?? .distantPast))
            }
        }
        return objects
    }

    /// The first `count` bytes of an object, or nil when it is not there — enough to tell
    /// a document that names other objects from a file that does not, without reading a
    /// 57 MB executable to find out it is not a manifest.
    public func prefix(ofHash hash: String, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: objectURL(hash: hash)) else {
            return nil
        }
        defer { try? handle.close() }
        return try? handle.read(upToCount: count)
    }

    /// Up to `count` bytes of an object from `offset` — fewer at its end, none past it — or
    /// nil when it is not there: a header read where a fat binary says one is, without
    /// reading the 375 MB of archives behind it (B-77).
    ///
    /// Not checked against the hash, as `read(hash:)` is: that would read the whole object,
    /// which is what this exists not to do. A caller deciding something from a few bytes
    /// decides it from what the store holds, as `prefix(ofHash:count:)` does.
    public func bytes(ofHash hash: String, at offset: UInt64, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: objectURL(hash: hash)) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            return nil
        }
    }

    /// Deletes an object. Only the collector calls this, and only for an object nothing
    /// refers to; an object already gone is not an error.
    public func remove(hash: String) throws {
        let url = objectURL(hash: hash)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ObjectStoreError.cannotWrite(storeRoot: storeRoot.path, underlying: error)
        }
    }

    /// Bytes written to this store since the process started, across both ways in. What
    /// the collector's trigger reads: a store that has grown is one worth walking.
    public var bytesStored: Int {
        bytesStoredLock.withLock { bytesStoredCount }
    }

    private let bytesStoredLock = NSLock()
    private var bytesStoredCount = 0

    private func noteStored(bytes: Int) {
        bytesStoredLock.withLock {
            bytesStoredCount += bytes
            writeCounts.written += 1
        }
    }

    /// How often this store has been asked to keep an object since it was made: `written`
    /// for one it did not hold, each a file created on disk, and `touched` for one it held
    /// already, each a change to that file's modification date. A test observable: what a
    /// push or a fold costs the store is a count of these, which a test can pin where a
    /// timing could not be.
    public struct WriteCounts: Equatable {
        public var written = 0
        public var touched = 0

        public init(written: Int = 0, touched: Int = 0) {
            self.written = written
            self.touched = touched
        }
    }

    public var writes: WriteCounts {
        bytesStoredLock.withLock { writeCounts }
    }

    private var writeCounts = WriteCounts()

    /// An object interned again is in use again. Its modification date moves to now, so
    /// a collection that began before this intern — and so did not see whichever row is
    /// about to refer to it — leaves it alone by age. That is the one race a collector
    /// walking a snapshot of the graph has, and this is what closes it.
    private func touch(_ url: URL) {
        bytesStoredLock.withLock { writeCounts.touched += 1 }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    // MARK: - Reading

    /// Returns the stored bytes for `hash`, or `nil` if not present.
    ///
    /// The bytes are re-hashed and checked against the name they are filed under. In a
    /// content-addressed store that name *is* a claim about the content, and nothing
    /// verified it on the way out — so bit rot, a truncated write, a bad sector or a
    /// hand-edited store all produced a build that looked entirely successful. Re-hashing
    /// costs a fraction of the read it accompanies and closes the whole class.
    ///
    /// Corruption throws rather than reporting absence: a missing object is rebuilt
    /// silently, which is exactly the wrong response to a damaged store.
    public func read(hash: String) throws -> [UInt8]? {
        let url = objectURL(hash: hash)
        // Mapped, and hashed as mapped: the one copy made is the array handed back
        // (B-116). Objects are read-only once stored, so the mapping cannot change
        // under the hash.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            return nil
        }

        let actual = Sha256.hash(data)

        guard actual == hash else {
            throw ObjectStoreReadError.corrupted(expected: hash, actual: actual, path: url.path)
        }

        return [UInt8](data)
    }

    /// Returns the on-disk byte count for `hash`, or `nil` if not present.
    public func size(hash: String) -> Int? {
        (try? objectURL(hash: hash).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    // MARK: - Writing

    /// Persists `content` under `hash` (no-op if already present).
    ///
    /// Thread-safe: a second concurrent writer for the same hash is harmless —
    /// `Data.write(to:options:.atomic)` writes to a temp file and renames, so
    /// the final entry is always coherent.  The first writer wins the rename race;
    /// subsequent writers silently leave the existing entry untouched.
    public func store(hash: String, content: [UInt8]) throws {
        let url = objectURL(hash: hash)

        guard !FileManager.default.fileExists(atPath: url.path) else {
            touch(url)
            return
        }
        noteStored(bytes: content.count)

        // Every failure here is a property of the volume, not of the content being
        // stored: out of space, read-only mount, permissions. The next node would hit
        // exactly the same wall, so this is unrecoverable rather than a node error.
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // Written from the array's own buffer to a temporary name, then renamed:
            // atomic, as `Data.write(options: .atomic)` is, without the copy into a
            // `Data` first (B-116).
            let temporary = temporaryURL(beside: url)
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            do {
                let handle = try FileHandle(forWritingTo: temporary)
                try content.withUnsafeBytes { try handle.write(contentsOf: $0) }
                try handle.close()
                try place(temporary, at: url)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        } catch {
            throw ObjectStoreError.cannotWrite(storeRoot: storeRoot.path, underlying: error)
        }
    }

    /// Persists the file at `source` and returns its content hash — the same hash its
    /// bytes would intern to — without reading it into memory (B-116). The file is
    /// hashed mapped and then *cloned* into the store: on APFS a clone shares blocks
    /// with the source until either side is written, so storing a 57 MB executable costs
    /// its hash and nothing else. Across volumes, or on a file system without clones, the
    /// file is copied — one copy, still through no buffer of ours.
    ///
    /// The source is the caller's to dispose of afterwards; a tool's sandbox is deleted
    /// with it, and the stored object is unaffected. A source that is rewritten after
    /// storing leaves the object as it was: the clone's blocks copy on write.
    public func store(fileAt source: URL) throws -> DataObjectHash {
        let data: Data
        do {
            data = try Data(contentsOf: source, options: .alwaysMapped)
        } catch {
            throw ObjectStoreError.cannotWrite(storeRoot: storeRoot.path, underlying: error)
        }
        // The same two rules `intern()` applies: nothing is the empty hash, and an object
        // no longer than a digest is filed under its own bytes (`Sha256.hash`).
        guard !data.isEmpty else {
            return ""
        }
        let hash = Sha256.hash(data)
        let url = objectURL(hash: hash)

        guard !FileManager.default.fileExists(atPath: url.path) else {
            touch(url)
            return hash
        }
        noteStored(bytes: data.count)

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Not created in advance: the clone, or the copy, makes the file.
            let temporary = temporaryURL(beside: url)
            do {
                // A path with no file-system spelling is not cloned, and the copy says why.
                let cloned = Self.withFileSystemPaths(source, temporary) { sourcePath, temporaryPath in
                    Foundation.clonefileat(AT_FDCWD, sourcePath, AT_FDCWD, temporaryPath, 0) == 0
                } ?? false
                if !cloned {
                    try FileManager.default.copyItem(at: source, to: temporary)
                }
                try place(temporary, at: url)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        } catch {
            throw ObjectStoreError.cannotWrite(storeRoot: storeRoot.path, underlying: error)
        }
        return hash
    }

    /// A name in the object's own shard for the bytes on their way in, so the rename that
    /// finishes them never crosses a file system.
    private func temporaryURL(beside url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
    }

    /// Runs a system call taking two paths with both URLs as the file system spells them,
    /// or returns nil when either has no such spelling — which Foundation reports as a nil
    /// pointer, and which the caller decides the meaning of.
    private static func withFileSystemPaths<Outcome>(
        _ first: URL, _ second: URL,
        _ call: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Outcome
    ) -> Outcome? {
        first.withUnsafeFileSystemRepresentation { firstPath in
            second.withUnsafeFileSystemRepresentation { secondPath in
                guard let firstPath, let secondPath else {
                    return nil
                }
                return call(firstPath, secondPath)
            }
        }
    }

    /// Makes `temporary` the object at `url`: read-only, then renamed into place. A second
    /// writer of the same object loses the rename and its bytes are dropped — the two are
    /// identical by construction, which is what content addressing means.
    private func place(_ temporary: URL, at url: URL) throws {
        // Mark immutable so nothing can accidentally overwrite the entry.
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o444)], ofItemAtPath: temporary.path)
        guard let renamed = Self.withFileSystemPaths(temporary, url, { temporaryPath, finalPath in
            Foundation.renamex_np(temporaryPath, finalPath, UInt32(RENAME_EXCL)) == 0
        }) else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard renamed else {
            let failure = errno
            try? FileManager.default.removeItem(at: temporary)
            guard failure == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
            return
        }
    }

    // MARK: - Projecting into a sandbox

    /// Returns all hashes present in the store by walking the shard directories.
    public func allHashes() -> [String] {
        var hashes: [String] = []
        let fm = FileManager.default
        guard let shards = try? fm.contentsOfDirectory(atPath: storeRoot.path) else {
            return []
        }
        for shard in shards {
            let shardURL = storeRoot.appendingPathComponent(shard)
            guard let entries = try? fm.contentsOfDirectory(atPath: shardURL.path) else { continue }
            hashes.append(contentsOf: entries)
        }
        return hashes
    }

    /// Copies the stored object into `destination` using an APFS clone.
    ///
    /// On APFS the clone is copy-on-write, making it essentially free.
    /// On non-APFS volumes (HFS+, network mounts, Docker bind mounts) the
    /// call falls back to a regular `FileManager.copyItem`, which is still
    /// cheaper than re-extracting bytes from the database.
    public func project(hash: String, to destination: URL) throws {
        let source = objectURL(hash: hash)

        guard FileManager.default.fileExists(atPath: source.path) else {
            throw DataObjectError.dataObjectNotFoundByHash
        }

        try? FileManager.default.removeItem(at: destination)

        // A path with no file-system spelling is not cloned, and the copy says why.
        let cloned = Self.withFileSystemPaths(source, destination) { sourcePath, destinationPath in
            Foundation.clonefileat(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, 0) == 0
        } ?? false

        if !cloned {
            // The clone is an APFS optimisation; this is the path taken on HFS+, network
            // mounts and Docker bind mounts. Failing here means the destination volume is
            // full or unwritable, not that anything is wrong with the object — same class as
            // a failed store write, and every node projecting inputs next hits the same wall.
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                throw ObjectStoreError.cannotProject(destination: destination.path,
                                                     underlying: error)
            }
        }
    }

    /// Ensures `content` is stored under `hash`, then projects to `destination`.
    public func storeAndProject(hash: String, content: [UInt8], to destination: URL) throws {
        try store(hash: hash, content: content)
        try project(hash: hash, to: destination)
    }
}

extension Sequence<UInt8> {
    public func asHex() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

public struct Sha256 {
    /// The name an object is filed under: its SHA-256 as hex — or, for an object no longer
    /// than a digest, its own bytes as hex, which is shorter and just as unique. Hashed in
    /// place, whatever the bytes are held in: an array, or a file mapped into memory.
    public static func hash(_ data: some DataProtocol) -> String {
        let hash = [UInt8](SHA256.hash(data: data))
        guard hash.count < data.count else {
            return [UInt8](data).asHex()
        }
        return hash.asHex()
    }
}

/// A stored object whose bytes no longer match the hash they are filed under.
///
/// Deliberately *not* an `UnrecoverableError`: one damaged object fails the nodes that
/// need it, while the rest of the build carries on and reports the rest of its errors.
/// Deleting the named file makes it rebuild, which is why the path is in the message.
public enum ObjectStoreReadError: Error, CustomStringConvertible {
    case corrupted(expected: String, actual: String, path: String)

    public var description: String {
        switch self {
        case .corrupted(let expected, let actual, let path):
            return "Object store corruption: \(path) is filed as \(expected) but its bytes "
                 + "hash to \(actual). Delete that file to have it rebuilt."
        }
    }
}

/// Failures writing the content-addressed store.  Unrecoverable: the store is where every
/// build output lives, so if it cannot be written nothing further can succeed.
public enum ObjectStoreError: UnrecoverableError {
    case cannotWrite(storeRoot: String, underlying: Error)
    case cannotProject(destination: String, underlying: Error)

    public var unrecoverableDescription: String {
        switch self {
        case .cannotWrite(let storeRoot, let underlying):
            return """
                Could not write to the object store at \(storeRoot).

                \(underlying.localizedDescription)

                Every build output is stored there, so the build cannot proceed. Check
                free space and permissions on that volume.
                """

        case .cannotProject(let destination, let underlying):
            return """
                Could not place a build input at \(destination).

                \(underlying.localizedDescription)

                Every tool is given its inputs this way, so the build cannot proceed. Check
                free space and permissions on that volume.
                """
        }
    }
}
