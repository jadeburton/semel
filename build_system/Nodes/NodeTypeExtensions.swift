// NodeFunctionExtensions.swift
// build_system
//
// Shared extensions on NodeFunction used by tool nodes (preprocessor, compiler, linker).

import Foundation

extension NodeFunction {
    /// Reads a PolySerializable configuration object from the given input port.
    /// Returns nil when no wire is connected or the wire has no value yet.
    func readConfiguration<C: PolySerializable>(fromInputPort inputPort: String) throws -> C {
        try PolyFactory.decodeAndCast(encodedJSON: readOneValueFromInputPort(inputPort).dataObjectHash.resolveAsString())
    }
}
