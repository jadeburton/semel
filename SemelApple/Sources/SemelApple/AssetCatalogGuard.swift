//
//  AssetCatalogGuard.swift
//  SemelApple
//
//  The check that a canonical `Assets.car` is still the catalog actool wrote, made by the
//  reader Apple ships rather than by ours: `assetutil --info` over both files, compared
//  with the fields the canonicaliser changes taken out. What is left must be equal — every
//  catalog fact, every rendition's name, type, size, appearance, scale, idiom and digest —
//  and a canonical file assetutil cannot read is a failure too. Either fails the build
//  (B-89): a node that cannot show its canonical form is the catalog publishes nothing.
//
//  What is taken out, and why each is safe to take out:
//
//  - The catalog's `Timestamp`. The header's own timestamp is zero, so assetutil prints the
//    file's modification time, which says when the file was laid out, not what is in it.
//  - A renamed rendition's `RenditionName`, mapped through the renames rather than dropped.
//  - Each rendition's `SHA1Digest` — a SHA-256 of the rendition's bytes, whatever the key
//    says — mapped through the digests the canonicaliser computed of each rendition before
//    and after. Mapped rather than dropped, so a rendition whose bytes the reader sees
//    differently from what was written fails.
//
//  The facet part an icon's facet names is not in assetutil's report at all; the
//  canonicaliser's own round trip is what checks it.
//

import Foundation
import SemelNodeKit
import SemelDatabaseModels

enum AssetCatalogGuardError: Error, CustomStringConvertible, Equatable {
    /// `which` is `the Assets.car actool wrote` or `the canonical Assets.car`.
    case unreadable(which: String, reason: String)
    case entryCountDiffers(original: Int, canonical: Int)
    case entriesDiffer([String])

    var description: String {
        switch self {
        case .unreadable(let which, let reason):
            return "assetutil cannot read \(which): \(reason)"
        case .entryCountDiffers(let original, let canonical):
            return "assetutil reads \(original) entries in the Assets.car actool wrote and \(canonical) in the canonical one"
        case .entriesDiffer(let differences):
            return "assetutil reads the canonical Assets.car differently from the one actool wrote:\n"
                 + differences.joined(separator: "\n")
        }
    }
}

struct AssetCatalogGuard {
    let assetutil: ToolRunner

    static let catalogFile = "Assets.car"
    static let timestampKey = "Timestamp"
    static let renditionNameKey = "RenditionName"
    static let digestKey = "SHA1Digest"
    /// How many differences a failure lists before it stops.
    static let differencesShown = 10

    func check(originalHash: DataObjectHash, canonicalHash: DataObjectHash, canonical: CanonicalAssetCatalog) throws {
        let original  = try report(of: originalHash, which: "the Assets.car actool wrote")
        let rewritten = try report(of: canonicalHash, which: "the canonical Assets.car")
        guard original.count == rewritten.count else {
            throw AssetCatalogGuardError.entryCountDiffers(original: original.count, canonical: rewritten.count)
        }

        var differences: [String] = []
        for (position, (originalEntry, canonicalEntry)) in zip(original, rewritten).enumerated() {
            let expected = Self.expected(originalEntry, isCatalog: position == 0, canonical: canonical)
            let actual   = Self.expected(canonicalEntry, isCatalog: position == 0, canonical: nil)
            guard !(expected as NSDictionary).isEqual(to: actual) else {
                continue
            }
            let label = (originalEntry["Name"] as? String).map { "'\($0)'" } ?? "the catalog"
            let named = Set(expected.keys).union(actual.keys).sorted().compactMap { key -> String? in
                let expectedValue = expected[key].map { "\($0)" } ?? "nothing"
                let actualValue   = actual[key].map { "\($0)" } ?? "nothing"
                guard expectedValue != actualValue else {
                    return nil
                }
                return "entry \(position) (\(label)): \(key) is \(actualValue), where \(expectedValue) was expected"
            }
            differences += named.isEmpty ? ["entry \(position) (\(label)) differs"] : named
        }
        guard differences.isEmpty else {
            let shown = Array(differences.prefix(Self.differencesShown))
            let more  = differences.count > shown.count ? ["and \(differences.count - shown.count) more"] : []
            throw AssetCatalogGuardError.entriesDiffer(shown + more)
        }
    }

    /// An entry as the canonical file should report it: the catalog without its timestamp;
    /// a rendition of the original with its name and digest carried through the
    /// canonicaliser's maps. `canonical` is nil for an entry already from the canonical file.
    private static func expected(_ entry: [String: Any], isCatalog: Bool, canonical: CanonicalAssetCatalog?) -> [String: Any] {
        var entry = entry
        if isCatalog {
            entry[timestampKey] = nil
        }
        guard let canonical else {
            return entry
        }
        if let name = entry[renditionNameKey] as? String, let renamed = canonical.renamedRenditions[name] {
            entry[renditionNameKey] = renamed
        }
        if let digest = entry[digestKey] as? String, let mapped = canonical.renditionDigests[digest] {
            entry[digestKey] = mapped
        }
        return entry
    }

    /// `assetutil --info` over one stored file, in a sandbox of its own: a JSON array, the
    /// catalog first and one entry per rendition after it.
    private func report(of hash: DataObjectHash, which: String) throws -> [[String: Any]] {
        let result = try assetutil.execute(arguments: ["--info", Self.catalogFile],
                                           environment: [:],
                                           inputFiles: [FileNameAndContent(filePath: Self.catalogFile, hash: hash)],
                                           expectedOutputFileNames: [])
        guard result.exitCode == 0 else {
            throw AssetCatalogGuardError.unreadable(which: which, reason: result.failureMessage(tool: "assetutil"))
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(result.infoOutput.utf8)),
              let entries = parsed as? [[String: Any]], !entries.isEmpty else {
            let printed = String(result.infoOutput.prefix(200))
            throw AssetCatalogGuardError.unreadable(which: which, reason: "it printed no catalog: \(printed)")
        }
        return entries
    }
}
