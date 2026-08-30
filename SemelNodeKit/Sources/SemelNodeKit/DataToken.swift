//
//  DataToken.swift
//  build_system
//

import Foundation
import SemelDatabaseModels

public typealias DataToken = DataObjectHash

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
    public func intern() throws -> DataToken {
        if isEmpty {
            return ""
        }

        let hash = Sha256.hash(self)
        // Write bytes to the filesystem store (idempotent).
        try DataObjectStore.shared.store(hash: hash, content: self)
        return hash
    }
}

extension String {
    public func intern() throws -> DataToken {
        try [UInt8](Data(utf8)).intern()
    }
}

// MARK: - Resolving a DataToken back to bytes

enum DataObjectError: Error {
    case dataObjectNotFoundByHash
}

extension DataToken {
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
