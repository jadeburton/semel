//
//  NodeValue.swift
//  semel
//

import Foundation
import SemelDatabaseModels

/// Why a port is carrying no value.
///
/// Each of these is a state the engine asks about by case. A reason that means "not a
/// value" but is not a failure of this node — a port that has never been processed, a node
/// whose input failed — is its own case rather than an `error` carrying a sentence, so that
/// anything deciding what to do about it reads the case instead of matching the text.
public enum NoValueReason: Codable {
    /// The node is waiting for something: a consumer must wait with it.
    case pending
    /// The state a port holds between its node's creation and its first processing. Not a
    /// failure — a graph full of fresh nodes is not a graph full of failures — and not
    /// something to wait on either, so a node reading it runs and makes of it what it can.
    case initializing
    /// The node did not run because one of its inputs is in error. It has nothing of its own
    /// to say, and a report folds it onto whatever failed upstream.
    case inputInError
    /// This node failed, and the message is its own.
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
            case .initializing, .inputInError, .error:
                // A consumer asking for a value it cannot have is told the same thing
                // whichever of these it met: there is no value, and this node cannot run.
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

// MARK: - SemelDatabaseModels.Port → NodeValue

extension SemelDatabaseModels.OutputPort {
    public func asNodeValue() throws -> NodeValue {
        try .init(port: self)
    }
}

// MARK: - NodeValue helpers

extension NodeValue {
    init(port: SemelDatabaseModels.OutputPort) throws {
        switch port.valueKind {

        case .pending:
            self = .noValue(reason: .pending)

        case .initializing:
            self = .noValue(reason: .initializing)

        case .inputInError:
            self = .noValue(reason: .inputInError)

        case .error:
            self = try .noValue(reason: .error(messageDataObjectHash: port.dataObjectHash ?? "<unknown>".intern()))

        case .value:

            guard let dataObjectHash = port.dataObjectHash else {
                throw PortError.dataObjectHashNotSetOnPort
            }

            self = .value(dataObjectHash)
        }
    }

    public func asOutputPort(nodeID: ObjectID, outputSymbolID: ObjectID) throws -> OutputPort {
        switch self {

        case .noValue(let reason):

            switch reason {

            case .pending:
                return .init(nodeID: nodeID,
                             nameSymbolID: outputSymbolID,
                             valueKind: .pending,
                             dataObjectHash: nil)

            case .initializing:
                return .init(nodeID: nodeID,
                             nameSymbolID: outputSymbolID,
                             valueKind: .initializing,
                             dataObjectHash: nil)

            case .inputInError:
                return .init(nodeID: nodeID,
                             nameSymbolID: outputSymbolID,
                             valueKind: .inputInError,
                             dataObjectHash: nil)

            case .error(let messageDataObjectHash):
                return .init(nodeID: nodeID,
                             nameSymbolID: outputSymbolID,
                             valueKind: .error,
                             dataObjectHash: messageDataObjectHash)

            }

        case .value(let dataObjectHash):
            return .init(nodeID: nodeID,
                         nameSymbolID: outputSymbolID,
                         valueKind: .value,
                         dataObjectHash: dataObjectHash)
        }
    }
}
