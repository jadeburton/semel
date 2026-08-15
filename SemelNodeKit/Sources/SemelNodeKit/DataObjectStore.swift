// DataObjectStore.swift
// build_system
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
//   ~/Library/Application Support/build_system/objects/<xx>/<sha256hash>
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
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(storeRoot: appSupport.appendingPathComponent("build_system/objects",
                                                               isDirectory: true))
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
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)

        let actual = Sha256.hash(bytes)
        guard actual == hash else {
            throw ObjectStoreReadError.corrupted(expected: hash, actual: actual, path: url.path)
        }
        return bytes
    }

    /// Returns the on-disk byte count for `hash`, or `nil` if not present.
    public func size(hash: String) -> Int? {
        let url = objectURL(hash: hash)
        return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
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
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        // Every failure here is a property of the volume, not of the content being
        // stored: out of space, read-only mount, permissions. The next node would hit
        // exactly the same wall, so this is unrecoverable rather than a node error.
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(content).write(to: url, options: .atomic)
            // Mark immutable so nothing can accidentally overwrite the entry.
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o444)],
                ofItemAtPath: url.path)
        } catch {
            throw ObjectStoreError.cannotWrite(storeRoot: storeRoot.path, underlying: error)
        }
    }

    // MARK: - Projecting into a sandbox

    /// Returns all hashes present in the store by walking the shard directories.
    public func allHashes() -> [String] {
        var hashes: [String] = []
        let fm = FileManager.default
        guard let shards = try? fm.contentsOfDirectory(atPath: storeRoot.path) else { return [] }
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

        let cloneResult = source.withUnsafeFileSystemRepresentation { srcPtr in
            destination.withUnsafeFileSystemRepresentation { dstPtr in
                Foundation.clonefileat(AT_FDCWD, srcPtr!, AT_FDCWD, dstPtr!, 0)
            }
        }

        if cloneResult != 0 {
            try FileManager.default.copyItem(at: source, to: destination)
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
    public static func hash(_ data: [UInt8]) -> String {
        let hash = [UInt8](SHA256.hash(data: Data(data)))
        let final = (hash.count < data.count) ? hash : data
        return final.asHex()
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

    public var unrecoverableDescription: String {
        switch self {
        case .cannotWrite(let storeRoot, let underlying):
            return """
                Could not write to the object store at \(storeRoot).

                \(underlying.localizedDescription)

                Every build output is stored there, so the build cannot proceed. Check
                free space and permissions on that volume.
                """
        }
    }
}
