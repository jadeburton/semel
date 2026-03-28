// NodeTypeExtensions.swift
// build_system
//
// Shared extensions on NodeType used by tool nodes (preprocessor, compiler, linker).

import Foundation

extension NodeType {
    /// Reads a PolySerializable configuration object from the given input port.
    /// Returns nil when no wire is connected or the wire has no value yet.
    func readConfiguration<C: PolySerializable>(fromInputPort inputPort: NodeKindDescriptor.InputPort) throws -> C? {
        guard let configurationNodeValue = try readOneValueFromInputPort(inputPort) else {
            // No wire is connected.
            return nil
        }

        switch configurationNodeValue.kind {
        case .value(let dataObjectHash, _):
            return try PolyFactory.decodeAndCast(encodedJSON: dataObjectHash.resolveAsString()) as C
        case .noValue:
            // The wire is connected but has no value yet.
            return nil
        }
    }
}
