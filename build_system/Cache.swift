//
//  Cache.swift
//  build_system
//
//  Created by Jade Burton on 14.06.26.
//

import Foundation

extension NodeFunction {

    func buildCacheKeyPartFromOneInput(inputPort: String, input: ProcessInput) throws -> String {
        let oneInput = input.inputValues[inputPort]!
        
        return try oneInput
            .sorted { $0.key < $1.key }
            .map { $0.value }
            .toJSON()
    }

    func buildCacheKeyFromAllInputs(input: ProcessInput) throws -> String? {
        if descriptor.staticInputPorts.isEmpty {
            return ""
        }

        var aggregated = try toJSON()

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

    func loadAndWriteCachedOutputs(thisNode: Node, database: DatabaseLayer, cacheKey: String?) throws -> Bool {

        guard let cacheKey else {
            return false
        }

        //        if !((self is ClangCompilerTool) || (self is ClangLinkerTool) || (self is ClangPreprocessorTool)) {
        //            return false
        //        }

        if descriptor.staticInputPorts.isEmpty && descriptor.dynamicInputPorts.isEmpty {
            return false
        }
        
        if descriptor.outputPorts.isEmpty {
            return false
        }
        
        guard let cacheEntry = try database.selectCacheEntry(hash: cacheKey) else {
            return false
        }
        
        guard let decodedCacheEntry = try? JSONDecoder().decode(ProcessCacheEntry.self, from: Data(cacheEntry.content)) else {
            return false
        }
        
        for outputPort in descriptor.outputPorts {
            if let outputValue = decodedCacheEntry.outputValues[outputPort] {
                print("Using cached output for node \(self.description()), output port \(outputPort)")
                try thisNode.writeToOutputPort(outputPort, value: outputValue, database: database)
            } else {
                // Invalid cache
                return false
            }
        }
        
        return true
    }

    func saveCacheForAllInputsAndOutputs(database: DatabaseLayer, cacheKey: String?, output: ProcessOutput) throws {
        guard let cacheKey else {
            return
        }

        if descriptor.staticInputPorts.isEmpty {
            return
        }

        if descriptor.outputPorts.isEmpty {
            return
        }

        // TODO! also the dynamic input expectations
        let cacheEntry = ProcessCacheEntry(outputValues: output.outputValues)
        let cacheEntryData = try cacheEntry.toJSON().data(using: .utf8)!
        try database.insertCacheEntry(.init(hash: cacheKey, content: [UInt8](cacheEntryData)))
    }
}
