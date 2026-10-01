//
//  Cache.swift
//  semel
//
//  Created by Jade Burton on 14.06.26.
//

import Foundation
import SemelNodeKit

private let cacheEntryLimit = 500

extension Node {

    /// The property `ProjectBuilder` stamps on every cacheable node it builds a product
    /// through.
    static var projectRootProperty: String { "projectRoot" }

    /// A wire key relative to the node's project root, when it has one and the key lies
    /// under it; the key whole otherwise. Two developers who point `base` at different
    /// folders put the same project at different places under `input:`; the remainder is
    /// what both builds have in common. A key of another shape — `wire0`, `product`,
    /// `modules/…` — keeps more in the key, never less. A wire equal to the root itself
    /// becomes `"."`, the empty remainder — otherwise it would key on the absolute path
    /// the root strips from every other wire.
    func projectRelative(wire: String) -> String {
        guard let root = thisNode.properties[Self.projectRootProperty], !root.isEmpty else {
            return wire
        }
        let trimmedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        if wire == trimmedRoot {
            return "."
        }
        let prefix = trimmedRoot + "/"
        guard wire.hasPrefix(prefix) else {
            return wire
        }
        return String(wire.dropFirst(prefix.count))
    }

    func buildCacheKeyEntriesFromOneInput(inputPort: String, input: ProcessInput) throws -> [CacheKeyEntry] {
        // Keying on a partial input set would produce a key that collides with a
        // different set of inputs — the one failure mode a cache must never have.
        guard let oneInput = input.inputValues[inputPort] else {
            throw NodeError.other(
                message: "Cannot build a cache key for \(type(of: self)): input port '\(inputPort)' has no entry")
        }

        // Both halves matter.  The wire key is the file's path, and the tools embed it —
        // in the object file's debug info, in the output filename derived from it, and in
        // the compiler output published on the log ports.  Keying on the values alone
        // meant identical content at a different path scored a hit and came back with
        // another file's build. The wire key therefore stays in the key whole: a
        // project-relative key is sound only once the sandbox materialises inputs at the
        // project-relative path and the command lines carry that path, which is what
        // `projectRelative(wire:)` is for and what B-49's remaining part owes.
        return oneInput
            .sorted { $0.key < $1.key }
            .map { CacheKeyEntry(port: inputPort, wire: $0.key, value: $0.value) }
    }

    /// Everything this node's key is taken of, in the order it is hashed: the node's type
    /// and the implementation of that type, its properties less the excluded ones,
    /// whatever it declares it reads from outside its inputs (`cacheKeyMaterial`), and
    /// every wired input with the value it carried.
    ///
    /// The implementation version is what makes an entry say which code produced it: a
    /// type that changes what it emits for equal inputs bumps it and stops hitting what it
    /// wrote before, while every other type keeps its entries.
    ///
    /// The key is the hash of this structure's canonical text and is computed nowhere
    /// else, so the material stored with an entry is the material that keyed it rather
    /// than a description of it that can drift.
    func buildCacheKeyMaterial(input: ProcessInput) throws -> CacheKeyMaterial {
        let excluded = Self.cacheKeyExcludedProperties
        let properties = thisNode.properties
            .filter { !excluded.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { CacheKeyProperty(key: $0.key, value: $0.value) }

        var inputs: [CacheKeyEntry] = []
        for inputPort in descriptor.staticInputPorts.sorted() + descriptor.dynamicInputPorts.sorted() {
            inputs += try buildCacheKeyEntriesFromOneInput(inputPort: inputPort, input: input)
        }

        return CacheKeyMaterial(nodeType: String(describing: type(of: self)),
                                implementationVersion: Self.implementationVersion,
                                properties: properties,
                                fingerprint: try cacheKeyMaterial(input: input),
                                inputs: inputs)
    }

    func buildCacheKeyFromAllInputs(input: ProcessInput) throws -> String? {
        try buildCacheKeyMaterial(input: input).cacheKey()
    }

    /// The entry stored under `cacheKey`, as the graph applies it: the values, and the
    /// demands as the stored table, which the applier walks by identity — no tree is built
    /// and none is hashed (B-121).
    func loadCachedOutputs(cacheKey: String?) throws -> AppliedOutput? {

        guard let cacheKey else {
            return nil
        }

        if descriptor.staticInputPorts.isEmpty && descriptor.dynamicInputPorts.isEmpty {
            return nil
        }

        if descriptor.outputPorts.isEmpty {
            return nil
        }

        guard let cacheEntry = try database.cacheEntry.select(hash: cacheKey) else {
            return nil
        }

        guard let decodedCacheEntry = try? JSONDecoder().decode(ProcessCacheEntry.self, from: cacheEntry.content) else {
            return nil
        }

        // An entry's specs demand a subgraph by naming node types, and a node type carries
        // no version for a type other than its own: a Semel that drops or renames a type
        // leaves entries of every *other* type naming something it cannot make. Applying
        // such an entry is recoverable — the throw writes an error value on every output
        // port and both hit paths reprocess — so this saves a replay that was going to be
        // thrown away, along with its warning and the error values the ports carry
        // meanwhile. Asked of the table's rows, so once per distinct node.
        guard decodedCacheEntry.specTable.namesOnlyRegisteredTypes() else {
            return nil
        }

        // A table naming a row it does not hold is damaged, and a damaged entry is a miss.
        // A lookup per reference, nothing hashed: a row filed under the wrong identity is
        // caught by the applier, which checks a row before making a node from it.
        guard decodedCacheEntry.specTable.referencesOnlyHeldRows() else {
            return nil
        }

        // Below every reason this lookup can answer nothing, so only a row that was used
        // counts as recently used. Eviction is by timestamp, so refreshing a row before
        // reading it makes the rejected ones the hardest to evict — an entry this Semel
        // cannot decode, or one demanding a type it does not link, would hold its slot in
        // the cache against the entries that do get used.
        //
        // Best effort: a stale timestamp only makes the entry evictable sooner.
        FatalErrors.attempt {
            try database.cacheEntry.updateTimestampAndCost(hash: cacheKey, cost: cacheEntry.cost, timestamp: Date())
        }

        Debug.log("using cache: \(type(of: self)), nodeID \(thisNode.id ?? -1)")

        return AppliedOutput(outputValues: decodedCacheEntry.outputValues,
                             specTable: decodedCacheEntry.specTable)
    }

    /// Stores one build under the key its material takes, and the material with it. The
    /// material rather than the key is what is passed in: an entry whose key nothing can
    /// account for is the state B-13 exists to remove, and taking the key here is what
    /// makes that impossible to reach.
    ///
    /// The output is the applied one, whose table is what was wired: the demands are
    /// folded once per run, for the graph and for the entry both.
    func saveCacheForAllInputsAndOutputs(keyMaterial: CacheKeyMaterial?,
                                         processingDuration: TimeInterval,
                                         output: AppliedOutput) throws {
        guard let keyMaterial else {
            return
        }
        let cacheKey = try keyMaterial.cacheKey()

        //Debug.log("Cache cost: \(Int(processingDuration * 1000.0)) ms")

        if descriptor.staticInputPorts.isEmpty {
            return
        }

        if descriptor.outputPorts.isEmpty {
            return
        }

        let thresholdDuration = 0.015 // 15ms

        // The floor is about new work: a build cheaper than storing and fetching it back is
        // not worth a row. It is not about a row already standing under this key whose
        // content this Semel cannot read — that row is a slot nothing can use, and this
        // build is the only thing that can put a usable entry in it. Left alone it would
        // wait for the whole cache to turn over under it. So the floor is asked second, and
        // a build of any cost replaces such a row.
        if processingDuration < thresholdDuration && !holdsAnUnreadableEntry(cacheKey: cacheKey) {
            return
        }

        //Debug.log("Saving cache entry..")

        let cacheEntry = ProcessCacheEntry(outputValues: output.outputValues,
                                           specTable: output.specTable,
                                           keyMaterial: keyMaterial)
        let cacheEntryData = Data(try cacheEntry.toJSON().utf8)

        // Replaces rather than refuses: a key whose row this Semel could not read is a key
        // it just missed on, and the build that missed is the one thing that can put a
        // readable entry there.
        try database.cacheEntry.save(.init(hash: cacheKey, content: cacheEntryData,
                                           cost: Int(processingDuration * 1000.0),
                                           timestamp: Date()))
        // Best effort: an untrimmed cache is over its limit until the next save trims it.
        FatalErrors.attempt { try database.cacheEntry.trimToLimit(cacheEntryLimit) }
    }

    /// Whether a row stands under this key that this Semel cannot decode — the entries an
    /// older or newer shape of `ProcessCacheEntry` left behind. One lookup by primary key,
    /// asked only of a build under the storage floor, which is the one case where the
    /// answer decides anything.
    private func holdsAnUnreadableEntry(cacheKey: String) -> Bool {
        guard let row = (FatalErrors.attempt { try database.cacheEntry.select(hash: cacheKey) }) ?? nil else {
            return false
        }
        return (try? JSONDecoder().decode(ProcessCacheEntry.self, from: row.content)) == nil
    }
}

/// One line of a key's material: the word that says what the line is about, and the thing
/// itself as JSON. Keys sorted so the text is the same on two machines, slashes left alone
/// so a wire's path reads as the path it is, and JSON rather than plain text so a value
/// holding a newline stays on its line and cannot forge another.
private func cacheKeyLine(_ keyword: String, _ item: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return "\(keyword) \(String(decoding: try encoder.encode(item), as: UTF8.self))"
}

/// One wired input as it contributes to a cache key: which port and which wire it arrived
/// on, and what it carried. All three are part of the build's identity.
///
/// Coded by hand so that a line reads `"value":"<hash>"` rather than the two wrappers the
/// synthesized encoding of a two-case enum over a string gives — the field a reader of a
/// diff scans is the one worth keeping short. A wire carrying no value keeps its reason
/// whole under a key of its own: which case it is *and* what that case carries, because
/// two failures with different messages are two different builds and must not hash alike.
struct CacheKeyEntry: Codable {
    let port: String
    let wire: String
    let value: NodeValue

    init(port: String, wire: String, value: NodeValue) {
        self.port  = port
        self.wire  = wire
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case port
        case wire
        case value
        case noValue
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(port, forKey: .port)
        try container.encode(wire, forKey: .wire)
        switch value {
        case .value(let hash):
            try container.encode(hash, forKey: .value)
        case .noValue(let reason):
            try container.encode(reason, forKey: .noValue)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decode(String.self, forKey: .port)
        wire = try container.decode(String.self, forKey: .wire)
        if let hash = try container.decodeIfPresent(DataObjectHash.self, forKey: .value) {
            value = .value(hash)
        } else {
            value = .noValue(reason: try container.decode(NoValueReason.self, forKey: .noValue))
        }
    }
}

/// One of the node's own properties as it contributes to a cache key.
struct CacheKeyProperty: Codable {
    let key: String
    let value: String
}

/// What a node reads from outside its inputs, as the node itself describes it — an SDK's
/// fingerprint and the like. A struct rather than a bare string so the text is JSON on one
/// line of the material, whatever the node put in it.
struct CacheKeyFingerprint: Codable {
    let fingerprint: String
}

/// Everything a cache key is taken of, as structure. Stored with the entry the key names,
/// so a mismatch between two builds is a diff of two of these and a key can be recomputed
/// where neither graph is.
///
/// The order of `inputs` is part of the key and is the order `buildCacheKeyMaterial`
/// builds them in — static ports sorted, then dynamic ports sorted, wires sorted within
/// each port. An array, not a dictionary, so what is stored is the order that was hashed.
struct CacheKeyMaterial: Codable {
    let nodeType: String
    let implementationVersion: Int
    let properties: [CacheKeyProperty]
    /// What `Node.cacheKeyMaterial(input:)` declared, or nil where a node reads nothing
    /// outside its inputs — which is most of them.
    let fingerprint: String?
    let inputs: [CacheKeyEntry]

    /// The text the key is the hash of: one line per thing the key covers, each named by
    /// the word it starts with and each carrying JSON, so a value holding a newline cannot
    /// forge a line and two materials differing in one input differ in one line.
    func canonicalText() throws -> String {
        var lines = ["node \(nodeType)@\(implementationVersion)"]
        lines += try properties.map { try cacheKeyLine("property", $0) }
        if let fingerprint {
            lines.append(try cacheKeyLine("fingerprint", CacheKeyFingerprint(fingerprint: fingerprint)))
        }
        lines += try inputs.map { try cacheKeyLine("input", $0) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The cache key itself. The one place a key is computed.
    func cacheKey() throws -> String {
        Sha256.hash(Array(try canonicalText().utf8))
    }
}

/// A cached ProcessOutput as stored, with the material its key was taken of. Lives with
/// the cache rather than with the node protocol. A field added here is non-optional, so an
/// entry written before it fails to decode and misses, rather than decoding short with a
/// default and hitting wrongly.
///
/// The demanded specs are stored as a table, each distinct spec node once (B-121): spelled
/// out as trees, one entry of a product builder's held the settings chain thousands of
/// times over and ran to 15 MB. The table is the one the run's output was applied from,
/// and a hit applies it again as it stands.
struct ProcessCacheEntry: Codable {
    let outputValues: [String: NodeValue]
    let specTable: GraphSpecTable
    let keyMaterial: CacheKeyMaterial
}

/// An output as the graph applies it: the values for the node's ports, and its demands as
/// a table (B-121). What a cache hit hands back, and what a run's output becomes once its
/// trees are folded — so one applier serves both, and the table a run applies is the one
/// its entry stores.
struct AppliedOutput {
    let outputValues: [String: NodeValue]
    let specTable: GraphSpecTable

    init(outputValues: [String: NodeValue], specTable: GraphSpecTable) {
        self.outputValues = outputValues
        self.specTable    = specTable
    }

    /// A run's output with its demanded trees folded, each node hashed once.
    init(folding output: ProcessOutput) throws {
        self.init(outputValues: output.outputValues, specTable: try GraphSpecTable.applied(trees: output.inputWireSpecs))
    }
}

/// What a node's computation hands the writer: a run's output, whose trees are folded as
/// it is written, or a hit's, whose table is applied as it was stored.
enum ComputedOutput {
    case processed(ProcessOutput)
    case cached(AppliedOutput)
}
