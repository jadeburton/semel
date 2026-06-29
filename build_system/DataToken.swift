
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
        if let _ = try! DatabaseLayer.shared.selectDataObject(hash: hash) {
            return hash
        } else {
            try! DatabaseLayer.shared.insertDataObject(DataObject(hash: hash, content: self))
            return hash
        }
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

        guard let dataObject = try DatabaseLayer.shared.selectDataObject(hash: self) else {
            throw DataObjectError.dataObjectNotFoundByHash
        }

        return dataObject.content
    }

    func resolveAsString() throws -> String {
        String(decoding: try resolve(), as: Unicode.UTF8.self)
    }
}
