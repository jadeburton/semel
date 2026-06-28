//
//  NodeValue.swift
//  build_system
//

import Foundation
import DatabaseModels

enum NoValueReason: Codable {
    case pending
    case error(message: String)
}

enum NodeValue: Codable {
    case noValue(reason: NoValueReason)
    case value(_ value: DataObjectHash)
}

extension NodeValue {
    func expectValue() throws -> DataObjectHash {
        switch self {
        case .noValue:
            throw NodeError.missingInputs
        case .value(let value):
            return value
        }
    }

    var isNoValue: Bool {
        if case .noValue = self {
            return true
        } else {
            return false
        }
    }

    var isPending: Bool {
        if case .noValue(let reason) = self {
            if case .pending = reason {
                return true
            }
        }
        return false
    }
}

enum PortError: Error {
    case dataObjectHashNotSetOnPort
}

enum ProcessingCycleError: Error {
    case outputPortHasNoValue
}

// MARK: - DatabaseModels.Port → NodeValue

extension DatabaseModels.OutputPort {
    func asNodeValue() throws -> NodeValue {
        try .init(port: self)
    }
}

// MARK: - NodeValue helpers

extension NodeValue {
    init(port: DatabaseModels.OutputPort) throws {
        switch port.valueKind {

        case .pending:
            self = .noValue(reason: .pending)

        case .error:
            self = .noValue(reason: .error(message: (try? port.dataObjectHash?.resolveAsString()) ?? "<unknown>"))

        case .value:

            guard let dataObjectHash = port.dataObjectHash else {
                throw PortError.dataObjectHashNotSetOnPort
            }

            self = .value(dataObjectHash)
        }
    }

    func mapPort(nodeID: ObjectID, outputSymbolID: ObjectID) throws -> OutputPort {
        switch self {

        case .noValue(let reason):

            switch reason {
            case .pending:
                return OutputPort(nodeID: nodeID,
                                  nameSymbolID: outputSymbolID,
                                  valueKind: .pending,
                                  dataObjectHash: nil)

            case .error(let message):
                return OutputPort(nodeID: nodeID,
                                  nameSymbolID: outputSymbolID,
                                  valueKind: .error,
                                  dataObjectHash: message.intern())
            }

        case .value(let dataObjectHash):
            return OutputPort(nodeID: nodeID,
                              nameSymbolID: outputSymbolID,
                              valueKind: .value,
                              dataObjectHash: dataObjectHash)
        }
    }
}

// There are two kinds of values. Values with a mutation chain and simple values.
// A simple value replaces the last and must be parsed entirely as one object.
// This means it is not suited for very complex data structures such as a file system tree.
// A value with mutation chain is a series of deltas linked together to make a complete final value.
// Each delta is a custom format that is specific to the type of the value. For example, a list of
// files will have add-file, delete-file, replace-file delta objects.
// The first "link" in the mutation chain should not be special; all aspects of the value should
// be changeable just with mutations.
// With a simple value the SHA256 hash is the hash. With mutation chains the hash is a hash of the most
// recent mutation, which is computed as a SHA256 over the mutation itself plus a hash of the previous mutation.
// In this way it is possible to compare two mutation-chain values for equality, and also to look up cache values.
// The cache can itself contain mutation-chain values.
// When a Node detects an Input value has changed, it can keep track of the last mutation link (hash and index?)
// and then process just the new mutations since it last checked. This is much more scaleable than parsing
// the entire simple value.
// Simple values are better for values that flip-flop back and forth. If a mutation-chain value goes from
// A, B, A, B etc, this creates mutations each time, even if they are de-duplicated.

