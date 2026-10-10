// ByteCount.swift
// SemelNodeKit
//
// A size, as the engine, the server and the prompt pass one between them. Here rather than
// in the engine or the protocol because all three hold it, as `Path` and `Platform` are.

import Foundation

/// A number of bytes. A type of its own so that a size never travels as an integer whose
/// unit a reader has to guess — the cache limit is one, and the prompt's `20G` is turned
/// into one where it is typed and nowhere else.
public struct ByteCount: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let bytes: Int

    public init(bytes: Int) {
        self.bytes = bytes
    }

    public static let kibibyte = 1_024
    public static let mebibyte = 1_048_576
    public static let gibibyte = 1_073_741_824

    public static func gibibytes(_ count: Int) -> ByteCount {
        ByteCount(bytes: count * gibibyte)
    }

    public static func < (lhs: ByteCount, rhs: ByteCount) -> Bool {
        lhs.bytes < rhs.bytes
    }

    /// One decimal in the largest binary unit that keeps the number at least one: `512 B`,
    /// `28.6 MB`, `10.0 GB`. Binary units under the decimal names, as every size the
    /// engine reports is written.
    public var description: String {
        let units: [(divisor: Int, name: String)] = [(Self.gibibyte, "GB"), (Self.mebibyte, "MB"), (Self.kibibyte, "KB")]
        for unit in units where bytes >= unit.divisor {
            return "\(String(format: "%.1f", Double(bytes) / Double(unit.divisor))) \(unit.name)"
        }
        return "\(bytes) B"
    }
}
