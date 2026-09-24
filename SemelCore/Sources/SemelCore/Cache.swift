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

    func buildCacheKeyPartFromOneInput(inputPort: String, input: ProcessInput) throws -> String {
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
        return try oneInput
            .sorted { $0.key < $1.key }
            .map { CacheKeyEntry(wire: $0.key, value: $0.value) }
            .toJSON()
    }

    /// The node's own contribution: its type and the implementation of that type, its
    /// properties less the excluded ones, and whatever it declares it reads from outside
    /// its inputs (`cacheKeyMaterial`). The implementation version is what makes an entry
    /// say which code produced it: a type that changes what it emits for equal inputs bumps
    /// it and stops hitting what it wrote before, while every other type keeps its entries.
    private func nodeCacheKey(input: ProcessInput) throws -> String {
        let excluded = Self.cacheKeyExcludedProperties
        let properties = thisNode.properties.filter { !excluded.contains($0.key) }
        var key = "\(String(describing: type(of: self)))@\(Self.implementationVersion)\n\(properties.asPlainText())"
        if let material = try cacheKeyMaterial(input: input) {
            key.append("\n\(material)")
        }
        return key
    }

    func buildCacheKeyFromAllInputs(input: ProcessInput) throws -> String? {

        var aggregated = try nodeCacheKey(input: input)

        for inputPort in descriptor.staticInputPorts.sorted() {
            aggregated.append(try buildCacheKeyPartFromOneInput(inputPort: inputPort, input: input))
            aggregated.append("\n")
        }

        for inputPort in descriptor.dynamicInputPorts.sorted() {
            aggregated.append(try buildCacheKeyPartFromOneInput(inputPort: inputPort, input: input))
            aggregated.append("\n")
        }

        return Sha256.hash(Array(aggregated.utf8))
    }

    func loadCachedOutputs(cacheKey: String?) throws -> ProcessOutput? {

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
        // Refresh the timestamp so this entry is treated as recently used by the LRU eviction
        // policy. Best effort: a stale timestamp only makes the entry evictable sooner.
        FatalErrors.attempt {
            try database.cacheEntry.updateTimestampAndCost(hash: cacheKey, cost: cacheEntry.cost, timestamp: Date())
        }

        guard let decodedCacheEntry = try? JSONDecoder().decode(ProcessCacheEntry.self, from: Data(cacheEntry.content)) else {
            return nil
        }

        // An entry's specs demand a subgraph by naming node types, and a node type carries
        // no version for a type other than its own: a Semel that drops or renames a type
        // leaves entries of every *other* type naming something it cannot make. Handing
        // such an entry back fails the node on a type nothing can build, where a miss
        // recomputes and demands what this Semel does link.
        let demandedSpecs = decodedCacheEntry.inputWireSpecs.values.flatMap(\.values)
        guard demandedSpecs.allSatisfy({ GraphSpecNode.namesOnlyRegisteredTypes(spec: $0) }) else {
            return nil
        }

        Debug.log("using cache: \(type(of: self)), nodeID \(thisNode.id ?? -1)")

        return ProcessOutput(outputValues: decodedCacheEntry.outputValues,
                             inputWireSpecs: decodedCacheEntry.inputWireSpecs)
    }

    func saveCacheForAllInputsAndOutputs(cacheKey: String?, processingDuration: TimeInterval, output: ProcessOutput) throws {
        guard let cacheKey else {
            return
        }

        //Debug.log("Cache cost: \(Int(processingDuration * 1000.0)) ms")

        if descriptor.staticInputPorts.isEmpty {
            return
        }

        if descriptor.outputPorts.isEmpty {
            return
        }

        let thresholdDuration = 0.015 // 15ms

        if processingDuration < thresholdDuration {
            return
        }

        //Debug.log("Saving cache entry..")

        let cacheEntry = ProcessCacheEntry(outputValues: output.outputValues, inputWireSpecs: output.inputWireSpecs)
        let cacheEntryData = try cacheEntry.toJSON().data(using: .utf8)!

        try database.cacheEntry.insert(.init(hash: cacheKey, content: [UInt8](cacheEntryData),
                                             cost: Int(processingDuration * 1000.0),
                                             timestamp: Date()))
        // Best effort: an untrimmed cache is over its limit until the next save trims it.
        FatalErrors.attempt { try database.cacheEntry.trimToLimit(cacheEntryLimit) }
    }
}

/// One wired input as it contributes to a cache key: which wire it arrived on, and what
/// it carried. Both are part of the build's identity.
struct CacheKeyEntry: Codable {
    let wire: String
    let value: NodeValue
}

/// A cached ProcessOutput as stored. Lives with the cache rather than with the node
/// protocol, which is what it was filed under by accident of history.
struct ProcessCacheEntry: Codable {
    let outputValues: [String: NodeValue]
    let inputWireSpecs: [String: [String: String]]
}
