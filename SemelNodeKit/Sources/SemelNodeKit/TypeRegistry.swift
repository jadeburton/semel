//
//  TypeRegistry.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation
import SemelDatabaseModels

// MARK: - Protocol

public protocol WithKind {
    static var kind: UInt { get }
}

/// A type that can be serialized/deserialized polymorphically via a `kind` discriminator.
public protocol PolySerializable: Codable, WithKind {
}

// MARK: - Factory

/// Creates and serializes `PolySerializable` objects using a kind-based type registry.
public enum TypeRegistry {

    private static var kindCache = [UInt: WithKind.Type]()
    private static var nameCache = [String: WithKind.Type]()

    /// All polymorphic types must be registered with the factory before they can be serialized/deserialized.
    ///
    /// `kind` is one flat number space shared by every polymorphic type, so a duplicate is
    /// rejected rather than silently overwriting the earlier claimant — a collision would
    /// otherwise surface much later as a wrong-type decode somewhere unrelated.
    /// Re-registering the identical type is idempotent.
    public static func register(types: [WithKind.Type]) throws {
        for type in types {
            if let existing = kindCache[type.kind], existing != type {
                throw TypeRegistryError.duplicateKind(kind: type.kind,
                                                     existing: String(describing: existing),
                                                     duplicate: String(describing: type))
            }
            kindCache[type.kind] = type
            nameCache[String(describing: type)] = type
        }
    }

    public static func nodeType(forTypeName typeName: String) -> (any WithKind.Type)? {
        nameCache[typeName]
    }

    public static func type(kind: UInt) throws -> WithKind.Type {
        guard let type = kindCache[kind] else {
            throw TypeRegistryError.unknownKind(kind)
        }
        return type
    }

    public static func decodableType(kind: UInt) throws -> PolySerializable.Type {
        guard let type = try type(kind: kind) as? PolySerializable.Type else {
            throw TypeRegistryError.notPolySerializable(kind)
        }
        return type
    }

    /// Look up the `kind` discriminator for a type identified by its Swift type name.
    /// Used when reconstructing a node from a `GraphShapeNode` string.
    public static func kind(forTypeName typeName: String) throws -> UInt {
        guard let type = nameCache[typeName] else {
            throw TypeRegistryError.unknownTypeName(typeName)
        }
        return type.kind
    }

    /// Decode a `PolySerializable` from a JSON string that embeds its `kind`.
    public static func decode(encodedJSON: String) throws -> any PolySerializable {
        try Caddy.fromJSON(encodedJSON).object
    }

    public static func decodeAndCast<P: PolySerializable>(encodedJSON: String) throws -> P {
        let decoded = try decode(encodedJSON: encodedJSON)

        if let object = decoded as? P {
            return object
        }

        Debug.warn("expected type \(P.self), got \(Swift.type(of: decoded))")
        throw TypeRegistryError.unexpectedType
    }
}

public enum TypeRegistryError: Error, CustomStringConvertible {
    case unexpectedType
    case unknownTypeName(String)
    /// A kind arrived that nothing is registered for — most likely a peer built against a
    /// different version, or a malformed frame.
    case unknownKind(UInt)
    case notPolySerializable(UInt)
    case duplicateKind(kind: UInt, existing: String, duplicate: String)

    public var description: String {
        switch self {
        case .unexpectedType:
            return "decoded object was not of the expected type"
        case .unknownTypeName(let name):
            return "no type is registered under the name '\(name)'"
        case .unknownKind(let kind):
            return "no type is registered for kind \(kind)"
        case .notPolySerializable(let kind):
            return "the type registered for kind \(kind) is not PolySerializable"
        case .duplicateKind(let kind, let existing, let duplicate):
            return "kind \(kind) is claimed by both \(existing) and \(duplicate)"
        }
    }
}

extension PolySerializable {
    /// Encode a `PolySerializable` to a JSON string, embedding its `kind`.
    ///
    /// Must stay `public`. There is also a `public` `Encodable.toJSON()` below that writes
    /// no `kind` wrapper. While both lived in one module Swift picked this, more specific,
    /// overload — but an `internal` overload is simply invisible from another module, so
    /// callers outside silently resolved to the *other* one and produced JSON that
    /// TypeRegistry could not decode. It failed at runtime, not at compile time.
    public func toJSON() throws -> String {
        try Caddy(object: self).toJSON()
    }
}

// MARK: - Caddy (private wrapper that pairs kind + object for serialization)

/// Internal use. Wraps a `PolySerializable` during serialization to add a `kind` discriminator.
private struct Caddy: Codable {

    let object: PolySerializable

    init(object: PolySerializable) {
        self.object = object
    }

    // MARK: Codable

    enum CodingKeys: CodingKey {
        case kind
        case object
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(UInt.self, forKey: .kind)
        let concreteType = try TypeRegistry.decodableType(kind: kind)
        object = try container.decode(concreteType, forKey: .object)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Swift.type(of: object).kind, forKey: .kind)
        try container.encode(object, forKey: .object)
    }
}

// MARK: JSON helpers

extension Decodable {
    public static func fromJSON(_ string: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(string.utf8))
    }
}

extension Encodable {
    public func toJSON() throws -> String {
        String(data: try JSONEncoder().withSortedKeys().encode(self), encoding: .utf8)!
    }
}

extension JSONEncoder {
    /// Sorts the keys of all encoded dictionaries, for deterministic output.
    func withSortedKeys() -> JSONEncoder {
        outputFormatting.insert(.sortedKeys)
        return self
    }
}
