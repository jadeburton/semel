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
import CryptoKit

// MARK: - DataObjectStore

/// The canonical on-disk store for all DataObject content.
///
/// Content is immutable once written: a given hash always maps to the same
/// bytes, so entries are written once and never modified.  Files are marked
/// read-only (0o444) after being stored to enforce this invariant.
final class DataObjectStore {

    static let shared = DataObjectStore()

    private let storeRoot: URL

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storeRoot = appSupport.appendingPathComponent("build_system/objects", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    }

    // MARK: - Paths

    /// Canonical on-disk URL for the object with the given hash.
    func objectURL(hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        return storeRoot
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(hash)
    }

    // MARK: - Existence check

    func exists(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: objectURL(hash: hash).path)
    }

    // MARK: - Reading

    /// Returns the stored bytes for `hash`, or `nil` if not present.
    func read(hash: String) -> [UInt8]? {
        guard let data = try? Data(contentsOf: objectURL(hash: hash)) else { return nil }
        return [UInt8](data)
    }

    /// Returns the on-disk byte count for `hash`, or `nil` if not present.
    func size(hash: String) -> Int? {
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
    func store(hash: String, content: [UInt8]) throws {
        let url = objectURL(hash: hash)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(content).write(to: url, options: .atomic)
        // Mark immutable so nothing can accidentally overwrite the entry.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o444)],
            ofItemAtPath: url.path)
    }

    // MARK: - Projecting into a sandbox

    /// Returns all hashes present in the store by walking the shard directories.
    func allHashes() -> [String] {
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
    func project(hash: String, to destination: URL) throws {
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
    func storeAndProject(hash: String, content: [UInt8], to destination: URL) throws {
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
