
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

enum NodeValuePayload: Codable {
    /// A single value
    case dataObjectHash(DataObjectHash)
    /// A stream that continually grows
    case stream(streamID: String, currentLength: UInt64)
}

// NodeValueKind cannot use synthesised Codable because `metadata` is `any PolySerializable`,
// a protocol existential. We encode it as a JSON string via PolyFactory — the same approach
// used throughout the rest of this file.
enum NodeValueKind: Codable {
    case noValue(reason: NoValueReason)
    case value(_ value: NodeValuePayload, metadata: String?)
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
    case streamIDNotSetOnNodeOutputValue
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

            if let lengthIfStream = nodeOutputValue.lengthIfStream {

                // Stream value

                let currentLength = UInt64(lengthIfStream)

                guard let streamID = nodeOutputValue.dataObjectHashOrStreamID else {
                    throw NodeOutputValueError.streamIDNotSetOnNodeOutputValue
                }

                if let metadata = nodeOutputValue.metadata {
                    self = .value(.stream(streamID: streamID,
                                          currentLength: currentLength),
                                  metadata: metadata)
                } else {
                    self = .value(.stream(streamID: streamID,
                                          currentLength: currentLength),
                                  metadata: nil)
                }
            } else {
                // Regular value

                guard let dataObjectHash = nodeOutputValue.dataObjectHashOrStreamID else {
                    throw NodeOutputValueError.dataObjectHashNotSetOnNodeOutputValue
                }

                if let metadata = nodeOutputValue.metadata {
                    self = .value(.dataObjectHash(dataObjectHash),
                                  metadata: metadata)
                } else {
                    self = .value(.dataObjectHash(dataObjectHash),
                                  metadata: nil)
                }
            }
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
                             dataObjectHashOrStreamID: nil,
                             metadata: nil,
                             errorMessage: nil)

            case .error(let message):
                return .init(nodeID: nodeID,
                             port: outputPortIndex,
                             kind: .error,
                             dataObjectHashOrStreamID: nil,
                             metadata: nil,
                             errorMessage: message)
            }

        case .value(let payload, let metadata):

            switch payload {
            case .dataObjectHash(let dataObjectHash):
                return .init(nodeID: nodeID,
                             port: outputPortIndex,
                             kind: .value,
                             dataObjectHashOrStreamID: dataObjectHash,
                             metadata: metadata,
                             errorMessage: nil)

            case .stream(let streamID, let currentLength):
                return .init(nodeID: nodeID,
                             port: outputPortIndex,
                             kind: .value,
                             dataObjectHashOrStreamID: streamID,
                             metadata: nil,
                             errorMessage: nil,
                             lengthIfStream: Int(currentLength))
            }
        }
    }
}
