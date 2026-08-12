//
//  DataToken.swift
//  build_system
//

import Foundation
import DatabaseModels

public typealias DataToken = DataObjectHash

// MARK: - Interning bytes / strings as DataObjects

extension [UInt8] {
    /// Stores these bytes in the object store and returns their content hash.
    ///
    /// Throws rather than trapping: the store is on disk, so this fails for ordinary
    /// reasons — a full volume, a permissions change, a read-only mount.  Those should
    /// fail the node being processed, not abort the build.
    public func intern() throws -> DataToken {
        if self.isEmpty {
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

        guard let bytes = DataObjectStore.shared.read(hash: self) else {
            throw DataObjectError.dataObjectNotFoundByHash
        }

        return bytes
    }

    public func resolveAsString() throws -> String {
        String(decoding: try resolve(), as: Unicode.UTF8.self)
    }
}
