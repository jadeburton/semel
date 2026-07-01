//
//  NodeValue.swift
//  build_system
//

import Foundation
import DatabaseModels

public enum NoValueReason: Codable {
    case pending
    case error(message: String)
}

public enum NodeValue: Codable {
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
