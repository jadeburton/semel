//
//  NodeValue.swift
//  build_system
//

import Foundation
import DatabaseModels

public enum NoValueReason: Codable {
    case pending
    case error(messageDataObjectHash: DataObjectHash)
}

public enum NodeValue: Codable {
    case noValue(reason: NoValueReason)
    case value(_ value: DataObjectHash)
}

extension NodeValue {
    public func expectValue() throws -> DataObjectHash {
        switch self {
        case .noValue(let reason):
            switch reason {
            case .pending:
                throw NodeError.inputValuePending
            case .error:
                throw NodeError.inputValueInError
            }
        case .value(let value):
            return value
        }
    }

    public var isNoValue: Bool {
        if case .noValue = self {
            return true
        } else {
            return false
        }
    }

    public var isPending: Bool {
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
    public func asNodeValue() throws -> NodeValue {
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
            self = try .noValue(reason: .error(messageDataObjectHash: port.dataObjectHash ?? "<unknown>".intern()))

        case .value:

            guard let dataObjectHash = port.dataObjectHash else {
                throw PortError.dataObjectHashNotSetOnPort
            }

            self = .value(dataObjectHash)
        }
    }

    public func mapPort(nodeID: ObjectID, outputSymbolID: ObjectID) throws -> OutputPort {
        switch self {

        case .noValue(let reason):

            switch reason {
            case .pending:
                return OutputPort(nodeID: nodeID,
                                  nameSymbolID: outputSymbolID,
                                  valueKind: .pending,
                                  dataObjectHash: nil)

            case .error(let messageDataObjectHash):
                return OutputPort(nodeID: nodeID,
                                  nameSymbolID: outputSymbolID,
                                  valueKind: .error,
                                  dataObjectHash: messageDataObjectHash)
            }

        case .value(let dataObjectHash):
            return OutputPort(nodeID: nodeID,
                              nameSymbolID: outputSymbolID,
                              valueKind: .value,
                              dataObjectHash: dataObjectHash)
        }
    }
}
