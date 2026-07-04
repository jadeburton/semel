//
//  DataToken.swift
//  build_system
//

import Foundation
import DatabaseModels

typealias DataToken = DataObjectHash

// MARK: - Interning bytes / strings as DataObjects

extension [UInt8] {
    func intern() -> DataToken {
        if self.isEmpty {
            return ""
        }

        let hash = Sha256.hash(self)
        // Write bytes to the filesystem store (idempotent).
        try! DataObjectStore.shared.store(hash: hash, content: self)
        return hash
    }
}

extension String {
    func intern() -> DataToken {
        [UInt8](data(using: .utf8)!).intern()
    }
}

// MARK: - Resolving a DataToken back to bytes

enum DataObjectError: Error {
    case dataObjectNotFoundByHash
}

extension DataToken {
    /// Reads the bytes for this token directly from the filesystem store —
    /// no database round-trip required.
    func resolve() throws -> [UInt8] {
        if isEmpty {
            return []
        }

        guard let bytes = DataObjectStore.shared.read(hash: self) else {
            throw DataObjectError.dataObjectNotFoundByHash
        }

        return bytes
    }

    func resolveAsString() throws -> String {
        String(decoding: try resolve(), as: Unicode.UTF8.self)
    }
}
