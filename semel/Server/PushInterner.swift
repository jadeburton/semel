// PushInterner.swift
// SemelServer
//
// The part of a push that reads no row: cutting a request's body into its files, hashing
// each, and writing it to the object store. Done on the thread that received the request
// and on every core, before the request takes the handler's serial queue, so that the one
// queue that writes the graph records hashes and computes none.

import Foundation
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol

/// One pushed file whose bytes are already in the object store: what the handler's queue
/// is given in place of the bytes.
struct InternedFile: Equatable {
    let path:        String
    let mode:        UInt16
    let contentHash: DataObjectHash
}

enum PushInterner {

    /// The files `headers` describe, their bytes cut from `body`, hashed and stored, in the
    /// headers' order.
    ///
    /// Each file on a core of its own. The store is safe for that: an object is written
    /// under a temporary name and renamed into place, so two files with the same bytes race
    /// to one rename and the loser's identical copy is dropped; and an object already there
    /// is touched, which is what keeps it from a collection that began before the graph's
    /// row naming it is written, as `intern()` on the queue did.
    ///
    /// The first failure, in the headers' order, is the one thrown: a store that cannot be
    /// written is the machine's and stops the server whichever file met it first, and a
    /// body the headers do not account for is refused before anything is stored.
    static func intern(_ headers: [PushedFileHeader], body: Data) throws -> [InternedFile] {
        let contents = try PushedFiles.contents(of: body, by: headers)

        var interned = [Result<DataObjectHash, Error>?](repeating: nil, count: contents.count)
        interned.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: contents.count) { index in
                slots[index] = Result { try [UInt8](contents[index]).intern() }
            }
        }

        return try zip(headers, interned).map { header, result in
            guard let result else {
                // `concurrentPerform` returns once every iteration has, so every slot is
                // filled; an empty one would be a hash the graph never got.
                throw PushInternerError.notInterned(path: header.path)
            }
            return InternedFile(path: header.path, mode: header.mode, contentHash: try result.get())
        }
    }
}

enum PushInternerError: Error, CustomStringConvertible {
    /// A file whose bytes were cut from the body and then never hashed.
    case notInterned(path: String)

    var description: String {
        switch self {
        case .notInterned(let path):
            return "\(path) was not hashed"
        }
    }
}
