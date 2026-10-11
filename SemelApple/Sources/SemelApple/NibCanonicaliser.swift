//
//  NibCanonicaliser.swift
//  SemelApple
//
//  What ibtool writes, in canonical form, and the check that the canonical form says what
//  ibtool's said (B-154).
//
//  ibtool is not a function of its input for a Mac storyboard. Measured on Xcode 26.6 with
//  Sequel Ace's `ProgressWindowController.storyboard`, compiled three times from one file:
//
//  - the `.storyboardc`'s `Info.plist` maps each view controller's identifier to a UUID
//    made afresh on every run (`NSViewControllerIdentifiersToUUIDs`), and the scenes' nibs
//    carry the same UUIDs;
//  - a scene's nib lists its connections in a different order each run, and with them the
//    order of the objects in the archive, the object-to-parent table and the object ids.
//    The connections are a set: the runtime makes each one, whatever their order.
//
//  So the node publishes each nib in a canonical form. Its connections are sorted by what
//  they connect. The tables pairing objects with their parents and their ids are sorted by
//  the objects, with the ids handed out again in that order. The objects are numbered in
//  the order a depth-first walk from the root reaches them, the keys sorted by name, and
//  the classes by first use. Each storyboard UUID is replaced by one derived from the
//  document and the identifier it stands for. The canonical archive is read back and
//  checked against ibtool's, object by object, through the renumbering: the same class,
//  the same values, references to the same objects. Anything else is an error, and
//  nothing is published. The three runs came out as one; the twenty-five xibs of Sequel
//  Ace and NetNewsWire's, which ibtool already wrote the same each run, are unchanged in
//  content.
//
//  What no canonical form can fix is a nib whose layout differs. Sequel Ace's
//  `ImportAccessory.xib` stores frames its constraints do not give, and ibtool, updating
//  them, puts its labels, pop-ups and tab view at one of two places from run to run. The
//  node compiles each document twice and refuses one whose two canonical forms differ
//  (`IBToolCompiler`).
//

import CryptoKit
import Foundation
import SemelDatabaseModels
import SemelNodeKit

enum NibCanonicaliser {

    /// What the canonical form of one archive is, and how its objects were renumbered.
    struct Result {
        let archive: NibArchive
        /// Each original object's index in the canonical archive.
        let newIndex: [Int]
    }

    /// The `NSIBObjectData` arrays that are sets: their elements' order is not meaning.
    static let unorderedArrays: Set<String> = ["NSConnections", "NSAccessibilityConnectors"]
    /// Parallel arrays pairing an object with another, sorted together by the pair.
    static let pairedArrays: [String: String] = ["NSObjectsKeys": "NSObjectsValues",
                                                 "NSAccessibilityOidsKeys": "NSAccessibilityOidsValues"]
    /// The object-id table: its keys are sorted, and its values — the ids, numbers handed
    /// out in order — stay where they are, so the ids are given out again in the new order.
    static let renumberedKeyArrays: Set<String> = ["NSOidsKeys"]
    static let elementKey = "UINibEncoderEmptyKey"
    static let objectDataClass = "NSIBObjectData"

    // MARK: - One archive

    /// `archive` in canonical form, its `data` values rewritten by `strings`.
    static func canonicalise(_ archive: NibArchive, strings: [[UInt8]: [UInt8]] = [:]) throws -> Result {
        var objects = archive.objects
        let keyNames = archive.keyTable.map { String(decoding: $0, as: UTF8.self) }
        let classNames = archive.classes.map(\.text)
        var number: [Int: Int] = [:]
        var order: [Int] = []

        /// Indices of the values of `array` that are its elements, in order.
        func elementSlots(_ array: Int) -> [Int] {
            objects[array].fields.indices.filter {
                keyNames[objects[array].fields[$0].key] == elementKey && objects[array].fields[$0].type == .object
            }
        }
        func elements(_ array: Int) -> [Int] {
            elementSlots(array).compactMap { objects[array].fields[$0].reference }
        }
        func reorder(_ array: Int, by permutation: [Int]) {
            let slots = elementSlots(array)
            let before = slots.map { objects[array].fields[$0] }
            for (slot, source) in zip(slots, permutation) {
                objects[array].fields[slot] = before[source]
            }
        }
        /// What an object is, without the indices ibtool gave it: an object already numbered
        /// by its canonical number, any other by its class and values, `depth` levels down.
        func signature(_ object: Int, depth: Int) -> String {
            if let canonical = number[object] {
                return "#\(canonical)"
            }
            var text = classNames[objects[object].classIndex] + "{"
            for value in objects[object].fields {
                text += keyNames[value.key] + "="
                if let reference = value.reference {
                    text += depth > 0 ? signature(reference, depth: depth - 1) : classNames[objects[reference].classIndex]
                } else {
                    let payload = strings[value.payload] ?? value.payload
                    text += "\(value.type.rawValue):" + payload.map { String(format: "%02x", $0) }.joined()
                }
                text += ";"
            }
            return text + "}"
        }
        /// The order of `items`: numbered objects by their numbers first, the rest by what
        /// they are.
        func sortKey(_ object: Int) -> (Int, Int, String) {
            number[object].map { (0, $0, "") } ?? (1, 0, signature(object, depth: 3))
        }
        func lessThan(_ first: (Int, Int, String), _ second: (Int, Int, String)) -> Bool {
            (first.0, first.1) != (second.0, second.1) ? (first.0, first.1) < (second.0, second.1) : first.2 < second.2
        }
        func arraysByName(_ object: Int) -> [String: Int] {
            var named: [String: Int] = [:]
            for value in objects[object].fields {
                if let reference = value.reference {
                    named[keyNames[value.key]] = reference
                }
            }
            return named
        }
        func sortUnordered(_ data: Int) {
            for (name, array) in arraysByName(data).sorted(by: { $0.key < $1.key }) where unorderedArrays.contains(name) {
                let items = elements(array)
                let keys = items.map(sortKey)
                reorder(array, by: items.indices.sorted { lessThan(keys[$0], keys[$1]) })
            }
        }
        func sortTables(_ data: Int) {
            let named = arraysByName(data)
            for (name, array) in named.sorted(by: { $0.key < $1.key }) {
                if let partner = pairedArrays[name].flatMap({ named[$0] }) {
                    let items = elements(array)
                    let partners = elements(partner)
                    guard items.count == partners.count else {
                        continue
                    }
                    let keys = items.map(sortKey)
                    let partnerKeys = partners.map(sortKey)
                    let permutation = items.indices.sorted { first, second in
                        lessThan(keys[first], keys[second])
                            || (!lessThan(keys[second], keys[first]) && lessThan(partnerKeys[first], partnerKeys[second]))
                    }
                    reorder(array, by: permutation)
                    reorder(partner, by: permutation)
                }
                if renumberedKeyArrays.contains(name) {
                    let items = elements(array)
                    let keys = items.map(sortKey)
                    reorder(array, by: items.indices.sorted { lessThan(keys[$0], keys[$1]) })
                }
            }
        }

        // Depth-first from the root, each object's values in their order. Inside the object
        // data, the connections are sorted when it is reached — their objects are not
        // numbered yet, so they sort by what they are — and the tables once everything
        // before them has been numbered, which is every object they name.
        var stack: [(object: Int, next: Int)] = []
        var tablesSorted = Set<Int>()
        func enter(_ object: Int) {
            number[object] = order.count
            order.append(object)
            if classNames[objects[object].classIndex] == objectDataClass {
                sortUnordered(object)
            }
            stack.append((object, 0))
        }
        if !objects.isEmpty {
            enter(0)
        }
        while var top = stack.popLast() {
            guard top.next < objects[top.object].fields.count else {
                continue
            }
            let value = objects[top.object].fields[top.next]
            if classNames[objects[top.object].classIndex] == objectDataClass,
               pairedArrays[keyNames[value.key]] != nil || renumberedKeyArrays.contains(keyNames[value.key]),
               tablesSorted.insert(top.object).inserted {
                sortTables(top.object)
            }
            top.next += 1
            stack.append(top)
            if let reference = objects[top.object].fields[top.next - 1].reference, number[reference] == nil {
                enter(reference)
            }
        }
        for index in objects.indices where number[index] == nil {
            number[index] = order.count
            order.append(index)
        }

        let keyOrder = archive.keyTable.indices.sorted { archive.keyTable[$0].lexicographicallyPrecedes(archive.keyTable[$1]) }
        var newKey = Array(repeating: 0, count: archive.keyTable.count)
        for (new, old) in keyOrder.enumerated() {
            newKey[old] = new
        }
        var classOrder: [Int] = []
        for index in order where !classOrder.contains(objects[index].classIndex) {
            classOrder.append(objects[index].classIndex)
        }
        classOrder += archive.classes.indices.filter { !classOrder.contains($0) }
        var newClass = Array(repeating: 0, count: archive.classes.count)
        for (new, old) in classOrder.enumerated() {
            newClass[old] = new
        }
        var newIndex = Array(repeating: 0, count: objects.count)
        for (new, old) in order.enumerated() {
            newIndex[old] = new
        }

        let canonicalObjects = order.map { old in
            NibArchive.Object(classIndex: newClass[objects[old].classIndex], fields: objects[old].fields.map { value in
                if let reference = value.reference {
                    return .referring(to: newIndex[reference], key: newKey[value.key])
                }
                return .init(key: newKey[value.key], type: value.type, payload: strings[value.payload] ?? value.payload)
            })
        }
        let canonicalClasses = try classOrder.map { old in
            NibArchive.ClassName(name: archive.classes[old].name, fallbacks: try archive.classes[old].fallbacks.map { fallback in
                guard fallback < newClass.count else {
                    throw NibProblem.indexOutOfRange
                }
                return newClass[fallback]
            })
        }
        return Result(archive: NibArchive(formatVersion: archive.formatVersion, coderVersion: archive.coderVersion,
                                          objects: canonicalObjects, keyTable: keyOrder.map { archive.keyTable[$0] },
                                          classes: canonicalClasses),
                      newIndex: newIndex)
    }

    /// Reads `canonical` back and checks it says what `original` said, object by object
    /// through the renumbering: the same class, the same values by key name, with the same
    /// strings rewritten and every reference to the same object. Values are compared as a
    /// collection per object, since the arrays that are sets were reordered.
    static func check(original: NibArchive, canonicalBytes: [UInt8], newIndex: [Int],
                      strings: [[UInt8]: [UInt8]]) throws {
        let canonical = try NibArchive(bytes: canonicalBytes)
        guard canonical.objects.count == original.objects.count, Set(canonical.keyTable) == Set(original.keyTable) else {
            throw NibProblem.readBackDiffers(object: -1)
        }
        func described(_ value: NibArchive.Value, in archive: NibArchive, mapping: (Int) -> Int,
                       rewriting: Bool) -> String {
            let key = String(decoding: archive.keyTable[value.key], as: UTF8.self)
            if let reference = value.reference {
                return "\(key)->\(mapping(reference))"
            }
            let payload = rewriting ? (strings[value.payload] ?? value.payload) : value.payload
            return "\(key):\(value.type.rawValue):" + payload.map { String(format: "%02x", $0) }.joined()
        }
        for (old, object) in original.objects.enumerated() {
            let new = newIndex[old]
            guard new < canonical.objects.count else {
                throw NibProblem.readBackDiffers(object: old)
            }
            let rewritten = canonical.objects[new]
            guard original.classes[object.classIndex].name == canonical.classes[rewritten.classIndex].name else {
                throw NibProblem.readBackDiffers(object: old)
            }
            let before = object.fields.map { described($0, in: original, mapping: { newIndex[$0] }, rewriting: true) }.sorted()
            let after  = rewritten.fields.map { described($0, in: canonical, mapping: { $0 }, rewriting: false) }.sorted()
            guard before == after else {
                throw NibProblem.readBackDiffers(object: old)
            }
        }
    }

    /// The canonical bytes of one archive, checked.
    static func canonicalBytes(of bytes: [UInt8], strings: [[UInt8]: [UInt8]]) throws -> [UInt8] {
        let original = try NibArchive(bytes: bytes)
        let result = try canonicalise(original, strings: strings)
        let canonical = result.archive.bytes()
        try check(original: original, canonicalBytes: canonical, newIndex: result.newIndex, strings: strings)
        return canonical
    }

    // MARK: - A compiled document

    /// What ibtool wrote for one document, in canonical form: every NIBArchive in it, and a
    /// storyboard's `Info.plist` with its view controllers' UUIDs derived from `document`
    /// and their identifiers. A file of any other form is left as it is: the node compiles
    /// twice and compares, which catches one that varies.
    static func canonicalTree(_ entries: [TreeManifestEntry], document: String) throws -> [TreeManifestEntry] {
        var strings: [[UInt8]: [UInt8]] = [:]
        for entry in entries where entry.path.hasSuffix(".storyboardc/Info.plist") {
            guard case .file(let hash, _) = entry.content else {
                continue
            }
            strings.merge(try storyboardUUIDs(in: try hash.resolve(), document: document, path: entry.path)) { first, _ in first }
        }
        return try entries.map { entry in
            guard case .file(let hash, let mode) = entry.content else {
                return entry
            }
            let bytes = try hash.resolve()
            let rewritten: [UInt8]
            if NibArchive.isArchive(bytes) {
                do {
                    rewritten = try canonicalBytes(of: bytes, strings: strings)
                } catch let problem as NibProblem {
                    throw ErrorCondition.nibNotCanonical(file: entry.path, problem: problem)
                }
            } else if entry.path.hasSuffix(".storyboardc/Info.plist") {
                rewritten = try rewritingStrings(bytes, strings, path: entry.path)
            } else {
                return entry
            }
            return TreeManifestEntry(path: entry.path, hash: try rewritten.intern(), mode: mode)
        }
    }

    /// The UUIDs a storyboard's `Info.plist` gives its view controllers, each with the one
    /// derived from the document and the identifier: the same for the same storyboard on
    /// every run, and different between two storyboards.
    static func storyboardUUIDs(in plist: [UInt8], document: String, path: String) throws -> [[UInt8]: [UInt8]] {
        guard let dictionary = try? PropertyListSerialization.propertyList(from: Data(plist), format: nil) as? [String: Any] else {
            throw ErrorCondition.nibNotCanonical(file: path, problem: .storyboardIndexUnreadable)
        }
        var mapping: [[UInt8]: [UInt8]] = [:]
        for (key, value) in dictionary.sorted(by: { $0.key < $1.key }) where key.hasSuffix("IdentifiersToUUIDs") {
            guard let uuids = value as? [String: String] else {
                throw ErrorCondition.nibNotCanonical(file: path, problem: .storyboardIndexUnreadable)
            }
            for (identifier, uuid) in uuids.sorted(by: { $0.key < $1.key }) {
                mapping[Array(uuid.utf8)] = Array(derivedUUID(document: document, identifier: identifier).utf8)
            }
        }
        return mapping
    }

    /// A version-4-shaped UUID from the SHA-256 of the document and the identifier.
    static func derivedUUID(document: String, identifier: String) -> String {
        var digest = Array(SHA256.hash(data: Data((document + "\u{0}" + identifier).utf8)).prefix(16))
        digest[6] = (digest[6] & 0x0f) | 0x40
        digest[8] = (digest[8] & 0x3f) | 0x80
        let hex = digest.map { String(format: "%02X", $0) }.joined()
        let characters = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(characters[$0]) }.joined(separator: "-")
    }

    /// `bytes` with each string of `strings` replaced by its partner, of the same length,
    /// so a binary property list's offsets hold. Checked by reading the result back.
    static func rewritingStrings(_ bytes: [UInt8], _ strings: [[UInt8]: [UInt8]], path: String) throws -> [UInt8] {
        var rewritten = Data(bytes)
        for (old, new) in strings.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) where old.count == new.count {
            var searchStart = rewritten.startIndex
            while let range = rewritten.range(of: Data(old), in: searchStart..<rewritten.endIndex) {
                rewritten.replaceSubrange(range, with: new)
                searchStart = range.upperBound
            }
        }
        guard (try? PropertyListSerialization.propertyList(from: rewritten, format: nil)) != nil else {
            throw ErrorCondition.nibNotCanonical(file: path, problem: .storyboardIndexUnreadable)
        }
        return [UInt8](rewritten)
    }
}
