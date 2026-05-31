
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

// NodeValueKind cannot use synthesised Codable because `metadata` is `any PolySerializable`,
// a protocol existential. We encode it as a JSON string via PolyFactory — the same approach
// used throughout the rest of this file.
enum NodeValueKind: Codable {
    case noValue(reason: NoValueReason)
    case value(_ value: DataObjectHash, metadata: String?)
}

struct NodeValue: Codable {
    let originNodeID: ObjectID
    let originOutputPort: UInt8
    let kind: NodeValueKind
}

extension NodeValue {
    var isNoValue: Bool {
        if case .noValue = kind {
            return true
        } else {
            return false
        }
    }
}

struct NodeValueAndWire: Codable {
    let originNodeID: ObjectID
    let originOutputPort: UInt8
    let kind: NodeValueKind
    let wire: Wire
}

enum NodeOutputValueError: Error {
    case dataObjectHashNotSetOnNodeOutputValue
}

enum ProcessingCycleError: Error {
    case outputPortHasNoValue
}

// MARK: - DatabaseModels.NodeOutputValue → NodeValue

extension DatabaseModels.NodeOutputValue {
    func asNodeOutputValue(wire: Wire) throws -> NodeValueAndWire {
        .init(originNodeID: nodeID,
              originOutputPort: port,
              kind: try .init(nodeOutputValue: self),
              wire: wire)
    }
    func asNodeOutputValue() throws -> NodeValue {
        .init(originNodeID: nodeID,
              originOutputPort: port,
              kind: try .init(nodeOutputValue: self))
    }
}

// MARK: - NodeValueKind helpers

extension NodeValueKind {
    init(nodeOutputValue: DatabaseModels.NodeOutputValue) throws {
        switch nodeOutputValue.kind {

        case .pending:
            self = .noValue(reason: .pending)

        case .error:
            self = .noValue(reason: .error(message: nodeOutputValue.errorMessage ?? "<unknown>"))

        case .value:

            guard let dataObjectHash = nodeOutputValue.dataObjectHash else {
                throw NodeOutputValueError.dataObjectHashNotSetOnNodeOutputValue
            }

            self = .value(dataObjectHash, metadata: nodeOutputValue.metadata)
        }
    }

    func mapNodeOutputValue(nodeID: ObjectID, outputPortIndex: UInt8) throws -> NodeOutputValue {
        switch self {

        case .noValue(let reason):

            switch reason {
            case .pending:
                return .init(nodeID: nodeID,
                             port: outputPortIndex,
                             kind: .pending,
                             dataObjectHash: nil,
                             metadata: nil,
                             errorMessage: nil)

            case .error(let message):
                return .init(nodeID: nodeID,
                             port: outputPortIndex,
                             kind: .error,
                             dataObjectHash: nil,
                             metadata: nil,
                             errorMessage: message)
            }

        case .value(let dataObjectHash, let metadata):
            return .init(nodeID: nodeID,
                         port: outputPortIndex,
                         kind: .value,
                         dataObjectHash: dataObjectHash,
                         metadata: metadata,
                         errorMessage: nil)
        }
    }
}
