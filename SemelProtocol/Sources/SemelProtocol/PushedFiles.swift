// PushedFiles.swift
// SemelProtocol
//
// What travels with a `pushFiles` request: a header per file in the JSON, and the files'
// bytes one after another in the frame body. Both ends cut and join the body here, so the
// rule that says where one file ends is written once.

import Foundation

/// One file of a `pushFiles` batch: where it goes, its mode, and how many bytes of the
/// frame body are its own.
///
/// A length rather than an offset: the bytes follow one another in the order of the
/// headers, so the lengths alone place every file, and a header cannot name bytes another
/// file also claims.
public struct PushedFileHeader: Codable, Equatable, Sendable {
    public let path:   String
    public let mode:   UInt16
    public let length: Int

    public init(path: String, mode: UInt16, length: Int) {
        self.path   = path
        self.mode   = mode
        self.length = length
    }
}

/// What became of one file of a `pushFiles` batch, in the order the headers named them.
public enum PushedFileOutcome: Codable, Equatable, Sendable {
    /// Stored; whether the bytes or the mode changed, as `pushFile(didChange:)` says it.
    case stored(didChange: Bool)
    /// The answer this file's own `pushFile` would have had. One file the graph refuses
    /// says nothing about the rest of the batch, which is stored all the same (B-130).
    case failed(error: ErrorResponse)
}

public enum PushedFilesError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The headers do not account for the body byte for byte.
    case bodyLengthMismatch(declared: Int, actual: Int)
    /// A header claims fewer than no bytes.
    case negativeLength(path: String, length: Int)

    public var description: String {
        switch self {
        case .bodyLengthMismatch(let declared, let actual):
            return "the files' lengths add up to \(declared) bytes and the body holds \(actual)"
        case .negativeLength(let path, let length):
            return "\(path) declares \(length) bytes"
        }
    }
}

public enum PushedFiles {

    /// The body of a `pushFiles` request: each file's bytes in turn, nothing between them.
    public static func body(joining contents: [Data]) -> Data {
        var body = Data(capacity: contents.reduce(0) { $0 + $1.count })
        for content in contents {
            body.append(content)
        }
        return body
    }

    /// Each file's bytes, cut from `body` by the headers' lengths. A body the headers do not
    /// account for exactly is refused whole: a length one short would shift every file
    /// after it, and storing those is worse than storing none.
    public static func contents(of body: Data, by headers: [PushedFileHeader]) throws -> [Data] {
        var declared = 0
        for header in headers {
            guard header.length >= 0 else {
                throw PushedFilesError.negativeLength(path: header.path, length: header.length)
            }
            declared += header.length
        }
        guard declared == body.count else {
            throw PushedFilesError.bodyLengthMismatch(declared: declared, actual: body.count)
        }

        var contents: [Data] = []
        contents.reserveCapacity(headers.count)
        var start = body.startIndex
        for header in headers {
            let end = start + header.length
            contents.append(body.subdata(in: start..<end))
            start = end
        }
        return contents
    }
}
