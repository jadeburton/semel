//
//  Cache.swift
//  build_system
//
//  Created by Jade Burton on 14.06.26.
//

import Foundation

private let cacheEntryLimit = 500

extension NodeFunction {

    func buildCacheKeyPartFromOneInput(inputPort: String, input: ProcessInput) throws -> String {
        let oneInput = input.inputValues[inputPort]!

        return try oneInput
            .sorted { $0.key < $1.key }
            .map { $0.value }
            .toJSON()
    }

    private var nodeFunctionCacheKey: String {
        "\(String(describing: type(of: self)))\nv\(Self.codeVersion)\n\(thisNode.properties.asPlainText())"
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

        print("using cache: \(type(of: self)), nodeID \(id!)")

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

        let thresholdDuration = 0.025 // 25ms

        if processingDuration < thresholdDuration {
            return
        }

        //print("Saving cache entry..")

        let cacheEntry = ProcessCacheEntry(outputValues: output.outputValues, inputWireExpectations: output.inputWireExpectations)
        let cacheEntryData = try cacheEntry.toJSON().data(using: .utf8)!

        try database.cacheEntry.insert(.init(hash: cacheKey, content: [UInt8](cacheEntryData),
                                             cost: Int(processingDuration * 1000.0),
                                             timestamp: Date()))
        try? database.cacheEntry.trimToLimit(cacheEntryLimit)
    }
}
