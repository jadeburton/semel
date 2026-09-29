//
//  AssetCatalogCanonicaliser.swift
//  SemelApple
//
//  `actool` is not a function of its inputs (B-89): two compiles of one catalog, each in a
//  fresh folder with the same arguments, can write different `Assets.car` files, and no
//  flag or environment variable turns that off. A node's output must be a function of its
//  inputs, so `AssetCatalogCompiler` puts the file in a canonical form before it publishes
//  it — inside the node, because a canonicaliser downstream would still leave the raw
//  file in the graph as a value, cached, stored and compared.
//
//  What varies, found by compiling IceCubesApp's, Food Truck's and NetNewsWire's catalogs
//  and a small `.icon` of our own repeatedly, each run in a fresh folder, and comparing
//  the files entry by entry (Xcode 26.6):
//
//  1. **Block numbering.** Which BOM block holds which key or value follows the order actool
//     allocated them in, and that order varies: the IceCubes widgets' two appearance names
//     traded blocks in two compiles of ten. `BOMStore.canonicallyNumbered()` renumbers.
//     The appearance *identifiers* never varied — they are CoreUI's own (Any 0, Dark 1,
//     Light 4, the tintable icon appearance 10), not an order to renumber.
//  2. **Generated rendition names.** From an Icon Composer `.icon`, actool renders images
//     it names `<name>_<UUID>-<pid>-<mach time>.png`, a fresh name every compile. The name
//     is in the rendition's CSI header and nowhere else; it becomes one derived from the
//     rendition's content.
//  3. **The facet of an icon stack.** An `.icon` is one facet with renditions of three
//     parts — the multisize set, the flattened images and the icon stack — and the facet's
//     own key names whichever part actool registered last: the flattened images in some
//     compiles, the stack in others. It becomes the stack's, one of the two actool writes.
//
//  Nothing else differed: the header's timestamp, UUID and checksum are zero, and the
//  extended metadata carries no time or process. A generated name left anywhere in the
//  canonical file is an error, so a new place actool writes one fails the build rather
//  than publishing a file that differs from the next compile.
//

import CryptoKit
import Foundation

// MARK: - Result

/// An `Assets.car` in canonical form, and what the guard needs to check it against the file
/// actool wrote: each rendition's new name, and each rendition's digest before and after.
struct CanonicalAssetCatalog {
    let bytes: [UInt8]
    /// A generated rendition name to the name that replaces it.
    let renamedRenditions: [String: String]
    /// Each rendition's SHA-256, uppercase hex as `assetutil` prints it, in the file actool
    /// wrote to the same rendition's in the canonical file. Equal for every rendition that
    /// was not renamed.
    let renditionDigests: [String: String]
}

// MARK: - Errors

enum AssetCatalogCanonicaliserError: Error, CustomStringConvertible {
    case unreadable(BOMStoreError)
    case missingVariable(String)
    case unknownIconFacetPart(facet: String, part: UInt16)
    case generatedNameRemains(offset: Int, text: String)
    case roundTripDiffers(variable: String)

    var description: String {
        switch self {
        case .unreadable(let error):
            return "Assets.car cannot be read as a BOM store: \(error)"
        case .missingVariable(let name):
            return "Assets.car has no \(name)"
        case .unknownIconFacetPart(let facet, let part):
            return "the facet '\(facet)' of an icon stack names part \(part), which is none of the icon's own parts"
        case .generatedNameRemains(let offset, let text):
            return "the canonical Assets.car still carries a generated name at byte \(offset): '\(text)'"
        case .roundTripDiffers(let variable):
            return "the canonical Assets.car does not read back as the catalog it was made from: \(variable) differs"
        }
    }
}

// MARK: - Canonicaliser

enum AssetCatalogCanonicaliser {

    /// The rendition's header: `ISTC`, then its name in a fixed 128-byte field at byte 40,
    /// NUL-padded.
    static let renditionMagic     = Array("ISTC".utf8)
    static let renditionNameStart = 40
    static let renditionNameSize  = 128

    /// CoreUI's rendition attributes a facet's key token and a rendition's key name.
    static let elementAttribute:    UInt16 = 1
    static let partAttribute:       UInt16 = 2
    static let identifierAttribute: UInt16 = 17

    /// The parts an Icon Composer icon's renditions take: the multisize image set, the
    /// flattened images and the icon stack. Only a facet with a rendition of the stack part
    /// is an icon's.
    static let iconStackPart: UInt16 = 245
    static let iconParts: Set<UInt16> = [218, 220, iconStackPart]

    static func canonicalise(_ original: [UInt8]) throws -> CanonicalAssetCatalog {
        var store: BOMStore
        do {
            store = try BOMStore(bytes: original)
        } catch let error as BOMStoreError {
            throw AssetCatalogCanonicaliserError.unreadable(error)
        }

        do {
            let renditions = try Self.variable("RENDITIONS", in: store)
            let renditionEntries = try BOMTree.leafEntries(store: store, variable: renditions)
            let originalDigests  = try renditionEntries.map { try digest(of: store.block($0.valueOrChild, referredToBy: "RENDITIONS")) }

            let renamed = try renameGeneratedRenditions(in: &store, entries: renditionEntries)
            try giveIconFacetsTheStackPart(in: &store, renditionEntries: renditionEntries)

            let canonical = try store.canonicallyNumbered()
            let bytes     = canonical.serialised()

            // The file read back must be the edited catalog, entry for entry, and must not
            // carry a generated name anywhere: the one checks the numbering and the writer,
            // the other that no place actool writes one has been missed.
            try checkRoundTrip(of: bytes, against: store)
            if let range = GeneratedName.firstRange(in: bytes[...]) {
                throw AssetCatalogCanonicaliserError.generatedNameRemains(
                    offset: range.lowerBound, text: String(decoding: bytes[range], as: UTF8.self))
            }

            let canonicalEntries = try BOMTree.leafEntries(store: canonical, variable: try Self.variable("RENDITIONS", in: canonical))
            let canonicalDigests = try canonicalEntries.map { try digest(of: canonical.block($0.valueOrChild, referredToBy: "RENDITIONS")) }
            return CanonicalAssetCatalog(bytes: bytes,
                                         renamedRenditions: renamed,
                                         renditionDigests: Dictionary(zip(originalDigests, canonicalDigests),
                                                                      uniquingKeysWith: { first, _ in first }))
        } catch let error as BOMStoreError {
            throw AssetCatalogCanonicaliserError.unreadable(error)
        }
    }

    private static func variable(_ name: String, in store: BOMStore) throws -> BOMStore.Variable {
        guard let variable = store.variable(named: name) else {
            throw AssetCatalogCanonicaliserError.missingVariable(name)
        }
        return variable
    }

    /// Uppercase hex SHA-256, as `assetutil --info` prints a rendition's `SHA1Digest`.
    static func digest(of bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
    }

    // MARK: Generated names

    /// Every rendition whose name carries a generated suffix gets one derived from what the
    /// renditions of that name hold, so a name is still shared by the renditions that
    /// shared it. The content is read with the name blanked, or the name would feed itself.
    private static func renameGeneratedRenditions(in store: inout BOMStore,
                                                  entries: [BOMTreeNode.Entry]) throws -> [String: String] {
        var contentDigestsByName: [String: Set<String>] = [:]
        var blocksByName: [String: Set<UInt32>] = [:]
        for entry in entries {
            let value = try store.block(entry.valueOrChild, referredToBy: "RENDITIONS")
            guard let name = renditionName(in: value), GeneratedName.firstRange(in: Array(name.utf8)[...]) != nil else {
                continue
            }
            var blanked = value
            blanked.replaceSubrange(renditionNameStart..<(renditionNameStart + renditionNameSize),
                                    with: [UInt8](repeating: 0, count: renditionNameSize))
            contentDigestsByName[name, default: []].insert(digest(of: blanked))
            blocksByName[name, default: []].insert(entry.valueOrChild)
        }

        var renamed: [String: String] = [:]
        for name in contentDigestsByName.keys.sorted() {
            let digests = contentDigestsByName[name, default: []].sorted().joined(separator: "\n")
            let token   = String(digest(of: Array(digests.utf8)).prefix(32))
            let nameBytes = Array(name.utf8)
            guard let range = GeneratedName.firstRange(in: nameBytes[...]) else {
                continue
            }
            let newName = String(decoding: nameBytes[..<range.lowerBound], as: UTF8.self) + token
                        + String(decoding: nameBytes[range.upperBound...], as: UTF8.self)
            renamed[name] = newName

            var field = Array(newName.utf8)
            field += [UInt8](repeating: 0, count: renditionNameSize - field.count)
            for block in blocksByName[name, default: []].sorted() {
                var value = try store.block(block, referredToBy: "RENDITIONS")
                value.replaceSubrange(renditionNameStart..<(renditionNameStart + renditionNameSize), with: field)
                store.blocks[Int(block)] = value
            }
        }
        return renamed
    }

    static func renditionName(in value: [UInt8]) -> String? {
        guard value.count >= renditionNameStart + renditionNameSize, Array(value[0..<4]) == renditionMagic else {
            return nil
        }
        let field = value[renditionNameStart..<(renditionNameStart + renditionNameSize)]
        return String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: Icon facets

    /// A facet's key token: a hot spot, a count, then that many attribute–value pairs,
    /// little-endian. The facet of an icon with a stack names the stack's part.
    private static func giveIconFacetsTheStackPart(in store: inout BOMStore,
                                                   renditionEntries: [BOMTreeNode.Entry]) throws {
        let keyFormat = try store.block(try variable("KEYFORMAT", in: store).block, referredToBy: "KEYFORMAT")
        guard keyFormat.count >= 12 else {
            throw AssetCatalogCanonicaliserError.missingVariable("KEYFORMAT")
        }
        let attributeCount = Int(keyFormat.littleEndianUInt32(at: 8))
        guard keyFormat.count >= 12 + 4 * attributeCount else {
            throw AssetCatalogCanonicaliserError.missingVariable("KEYFORMAT")
        }
        let attributes = (0..<attributeCount).map { UInt16(truncatingIfNeeded: keyFormat.littleEndianUInt32(at: 12 + 4 * $0)) }
        guard let elementPosition    = attributes.firstIndex(of: elementAttribute),
              let partPosition       = attributes.firstIndex(of: partAttribute),
              let identifierPosition = attributes.firstIndex(of: identifierAttribute) else {
            return
        }

        struct Named: Hashable {
            let element: UInt16
            let identifier: UInt16
        }
        var stacks = Set<Named>()
        for entry in renditionEntries {
            let key = try store.block(entry.key, referredToBy: "a key of RENDITIONS")
            guard key.count >= 2 * attributeCount else {
                continue
            }
            if key.littleEndianUInt16(at: 2 * partPosition) == iconStackPart {
                stacks.insert(Named(element: key.littleEndianUInt16(at: 2 * elementPosition),
                                    identifier: key.littleEndianUInt16(at: 2 * identifierPosition)))
            }
        }
        guard !stacks.isEmpty, let facets = store.variable(named: "FACETKEYS") else {
            return
        }

        for entry in try BOMTree.leafEntries(store: store, variable: facets) {
            var token = try store.block(entry.valueOrChild, referredToBy: "a value of FACETKEYS")
            guard token.count >= 6 else {
                continue
            }
            let pairCount = Int(token.littleEndianUInt16(at: 4))
            guard token.count >= 6 + 4 * pairCount else {
                continue
            }
            var values: [UInt16: (value: UInt16, offset: Int)] = [:]
            for pair in 0..<pairCount {
                let offset = 6 + 4 * pair
                values[token.littleEndianUInt16(at: offset)] = (token.littleEndianUInt16(at: offset + 2), offset + 2)
            }
            guard let element = values[elementAttribute]?.value, let identifier = values[identifierAttribute]?.value,
                  stacks.contains(Named(element: element, identifier: identifier)),
                  let part = values[partAttribute], part.value != iconStackPart else {
                continue
            }
            guard iconParts.contains(part.value) else {
                let facet = String(decoding: try store.block(entry.key, referredToBy: "a key of FACETKEYS"), as: UTF8.self)
                throw AssetCatalogCanonicaliserError.unknownIconFacetPart(facet: facet, part: part.value)
            }
            token.setLittleEndianUInt16(iconStackPart, at: part.offset)
            store.blocks[Int(entry.valueOrChild)] = token
        }
    }

    // MARK: Round trip

    /// The canonical bytes, read back, hold what the edited catalog held — every variable,
    /// every node, every key and value — with only the numbering changed.
    private static func checkRoundTrip(of bytes: [UInt8], against edited: BOMStore) throws {
        let expected = try edited.logicalView()
        let actual   = try BOMStore(bytes: bytes).logicalView()
        guard expected.map(\.name) == actual.map(\.name) else {
            throw AssetCatalogCanonicaliserError.roundTripDiffers(variable: "the variable table")
        }
        for (expectedVariable, actualVariable) in zip(expected, actual) where expectedVariable != actualVariable {
            throw AssetCatalogCanonicaliserError.roundTripDiffers(variable: expectedVariable.name)
        }
    }
}

// MARK: - Generated names

/// `<UUID>-<pid>-<mach time>`: 8-4-4-4-12 uppercase hex, a decimal process id, sixteen
/// uppercase hex digits. The shape of `NSProcessInfo.globallyUniqueString`, which is where
/// actool's temporary names come from.
enum GeneratedName {
    private static let groups = [8, 4, 4, 4, 12]

    static func firstRange(in bytes: ArraySlice<UInt8>) -> Range<Int>? {
        let minimumLength = 36 + 1 + 1 + 1 + 16
        guard bytes.count >= minimumLength else {
            return nil
        }
        // A whole catalog is scanned, megabytes of pixels, so the dashes that open a UUID are
        // looked at before anything else.
        let dash = UInt8(ascii: "-")
        var start = bytes.startIndex
        while start <= bytes.endIndex - minimumLength {
            if bytes[start + 8] == dash, bytes[start + 13] == dash, let end = match(in: bytes, from: start) {
                return start..<end
            }
            start += 1
        }
        return nil
    }

    private static func match(in bytes: ArraySlice<UInt8>, from start: Int) -> Int? {
        var position = start
        for (index, length) in groups.enumerated() {
            for _ in 0..<length {
                guard position < bytes.endIndex, isUppercaseHex(bytes[position]) else {
                    return nil
                }
                position += 1
            }
            if index < groups.count - 1 {
                guard position < bytes.endIndex, bytes[position] == UInt8(ascii: "-") else {
                    return nil
                }
                position += 1
            }
        }
        guard position < bytes.endIndex, bytes[position] == UInt8(ascii: "-") else {
            return nil
        }
        position += 1
        let digitsStart = position
        while position < bytes.endIndex, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) {
            position += 1
        }
        guard position > digitsStart, position < bytes.endIndex, bytes[position] == UInt8(ascii: "-") else {
            return nil
        }
        position += 1
        for _ in 0..<16 {
            guard position < bytes.endIndex, isUppercaseHex(bytes[position]) else {
                return nil
            }
            position += 1
        }
        return position
    }

    private static func isUppercaseHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }
}
