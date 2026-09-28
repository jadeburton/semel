//
//  Interning.swift
//  SemelNodeKit
//
//  Putting bytes in the object store and getting back the hash that names them.
//
//  The hash is the name: identical content interns to the same value from anywhere, which is
//  what makes a wire carry a reference rather than a copy and what lets two builds recognise
//  the same result.
//

import Foundation
import SemelDatabaseModels

// MARK: - Interning bytes / strings as DataObjects

extension [UInt8] {
    /// Stores these bytes in the object store and returns their content hash.
    ///
    /// The `throws` is transport, not a claim that the caller can recover. A store write
    /// fails for reasons that belong to the volume — full disk, read-only mount, permissions
    /// — and the next node would hit the same wall, so there is nothing to recover to. That
    /// is why `ObjectStoreError` is an `UnrecoverableError`: the throw carries it to the
    /// nearest `FatalErrors.check`, which prints what to do about it and exits 70.
    ///
    /// So this does stop the process, and trapping here instead would only make it worse:
    /// the message would become a Swift crash trace rather than "check free space and
    /// permissions on that volume", the exit code would be a signal rather than EX_SOFTWARE,
    /// and `UnrecoverableErrorTests` could not assert the classification without killing the
    /// test process — the handler is swappable precisely so it can.
    ///
    /// The cost is a `try` at every call site, which is real. It buys the message.
    public func intern() throws -> DataObjectHash {
        let hash = internedHash
        if !hash.isEmpty {
            // Write bytes to the filesystem store (idempotent).
            try DataObjectStore.shared.store(hash: hash, content: self)
        }
        return hash
    }

    /// The hash `intern()` names these bytes by, without storing them. For a caller that
    /// only asks whether a port already holds these bytes — a push of a file that has not
    /// changed — where storing them would be a write and a touch of a file on disk for an
    /// object the port already keeps alive (B-131).
    public var internedHash: DataObjectHash {
        isEmpty ? "" : Sha256.hash(self)
    }
}

extension String {
    public func intern() throws -> DataObjectHash {
        try [UInt8](Data(utf8)).intern()
    }

    /// `[UInt8].internedHash` of this string's UTF-8.
    public var internedHash: DataObjectHash {
        [UInt8](Data(utf8)).internedHash
    }
}

// MARK: - Resolving a DataObjectHash back to bytes

enum DataObjectError: Error {
    case dataObjectNotFoundByHash
}

extension DataObjectHash {
    /// Reads the bytes for this token directly from the filesystem store —
    /// no database round-trip required.
    public func resolve() throws -> [UInt8] {
        if isEmpty {
            return []
        }

        guard let bytes = try DataObjectStore.shared.read(hash: self) else {
            throw DataObjectError.dataObjectNotFoundByHash
        }

        return bytes
    }

    public func resolveAsString() throws -> String {
        .init(decoding: try resolve(), as: Unicode.UTF8.self)
    }

    /// Returns the byte count of the stored object without loading its contents.
    public func size() -> Int? {

        guard !isEmpty else {
            return 0
        }

        let url = DataObjectStore.shared.objectURL(hash: self)

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else {

            return nil
        }

        return size
    }
}
