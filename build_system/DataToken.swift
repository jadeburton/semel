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
        // INSERT OR IGNORE is atomic: concurrent tasks interning identical bytes
        // will not race — the second writer silently does nothing and both get
        // back the same hash that was committed by the first.
        try! DatabaseLayer.shared.dataObject.insertOrIgnore(DataObject(hash: hash, content: Data(self)))
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
    func resolve() throws -> [UInt8] {
        if isEmpty {
            return []
        }

        guard let dataObject = try DatabaseLayer.shared.dataObject.select(hash: self) else {
            throw DataObjectError.dataObjectNotFoundByHash
        }

        return [UInt8](dataObject.content)
    }

    func resolveAsString() throws -> String {
        String(decoding: try resolve(), as: Unicode.UTF8.self)
    }
}
