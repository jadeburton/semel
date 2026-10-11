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

    // MARK: - As a person writes one

    /// A size as a person writes one: bytes, or a number with `K`, `M` or `G` after it, in
    /// either case, binary as every size Semel prints is — `512M`, `1.5G`, `20g`. The prompt's
    /// `cache limit <size>` and the home's `semel.engine.config` read this one form, so a
    /// value a person copies from one to the other means the same in both.
    public init?(parsing text: String) {
        let multipliers: [Character: Int] = ["K": Self.kibibyte, "M": Self.mebibyte, "G": Self.gibibyte]
        var number = Substring(text)
        var multiplier = 1
        if let last = text.last, let unit = multipliers[Character(last.uppercased())] {
            multiplier = unit
            number = number.dropLast()
        }
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(number), value.isFinite, value >= 0 else {
            return nil
        }
        let bytes = value * Double(multiplier)
        guard bytes < Double(Int.max) else {
            return nil
        }
        self.init(bytes: Int(bytes.rounded()))
    }

    /// The size in that form, exactly: the largest unit that divides it, so it reads back as
    /// the same number of bytes — `10G`, `1536M`, `4097`. `description` rounds, for a reader;
    /// this is for a file.
    public var exactText: String {
        let units: [(divisor: Int, suffix: String)] = [(Self.gibibyte, "G"), (Self.mebibyte, "M"), (Self.kibibyte, "K")]
        for unit in units where bytes > 0 && bytes % unit.divisor == 0 {
            return "\(bytes / unit.divisor)\(unit.suffix)"
        }
        return "\(bytes)"
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
