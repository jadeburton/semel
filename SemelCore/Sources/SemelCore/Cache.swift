//
//  Cache.swift
//  build_system
//
//  Created by Jade Burton on 14.06.26.
//

import Foundation
import SemelNodeKit

private let cacheEntryLimit = 500

extension NodeFunction {

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
        // another file's build.
        return try oneInput
            .sorted { $0.key < $1.key }
            .map { CacheKeyEntry(wire: $0.key, value: $0.value) }
            .toJSON()
    }

    private var nodeFunctionCacheKey: String {
        "\(String(describing: type(of: self)))\n\(thisNode.properties.asPlainText())"
    }

    func buildCacheKeyFromAllInputs(input: ProcessInput) throws -> String? {

        var aggregated = nodeFunctionCacheKey

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
        // Refresh the timestamp so this entry is treated as recently used by the LRU eviction policy.
        try? database.cacheEntry.updateTimestampAndCost(hash: cacheKey, cost: cacheEntry.cost, timestamp: Date())

        guard let decodedCacheEntry = try? JSONDecoder().decode(ProcessCacheEntry.self, from: Data(cacheEntry.content)) else {
            return nil
        }

        Debug.log("using cache: \(type(of: self)), nodeID \(thisNode.id ?? -1)")

        return ProcessOutput(outputValues: decodedCacheEntry.outputValues,
                             inputWireExpectations: decodedCacheEntry.inputWireExpectations)
    }

    func saveCacheForAllInputsAndOutputs(cacheKey: String?, processingDuration: TimeInterval, output: ProcessOutput) throws {
        guard let cacheKey else {
            return
        }

        //print("Cache cost: \(Int(processingDuration * 1000.0)) ms")

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

        //print("Saving cache entry..")

        let cacheEntry = ProcessCacheEntry(outputValues: output.outputValues, inputWireExpectations: output.inputWireExpectations)
        let cacheEntryData = try cacheEntry.toJSON().data(using: .utf8)!

        try database.cacheEntry.insert(.init(hash: cacheKey, content: [UInt8](cacheEntryData),
                                             cost: Int(processingDuration * 1000.0),
                                             timestamp: Date()))
        _ = try? database.cacheEntry.trimToLimit(cacheEntryLimit)
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
    let inputWireExpectations: [String: [String: String]]
}
