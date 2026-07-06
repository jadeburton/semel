//
//  PolyFactory.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

// MARK: - Protocol

public protocol WithKind {
    static var kind: UInt { get }
}

/// A type that can be serialized/deserialized polymorphically via a `kind` discriminator.
public protocol PolySerializable: Codable, WithKind {
}

// MARK: - Factory

/// Creates and serializes `PolySerializable` objects using a kind-based type registry.
public enum PolyFactory {

    private static var registryCache = [UInt: WithKind.Type]()

    /// All polymorphic types must be registered with the factory before they can be serialized/deserialized.
    public static func register(types: [WithKind.Type]) {
        for type in types {
            registryCache[type.self.kind] = type
        }
    }

    /// Look up the concrete type for a given kind.
    public static func type(kind: UInt) throws -> WithKind.Type {
        guard let type = registryCache[kind] else {
            fatalError("Unknown object kind: \(kind)")
        }
        return type
    }

    public static func decodableType(kind: UInt) throws -> PolySerializable.Type {
        guard let type = registryCache[kind] as? PolySerializable.Type else {
            fatalError("Unknown object kind, or not PolySerializable: \(kind)")
        }
        return type
    }

    /// Look up the `kind` discriminator for a type identified by its Swift type name.
    /// Used when reconstructing a node from a `GraphShapeNode` string.
    public static func kind(forTypeName typeName: String) throws -> UInt {
        guard let entry = registryCache.first(where: { String(describing: $0.value) == typeName }) else {
            throw PolyFactoryError.unknownTypeName(typeName)
        }
        return entry.key
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

        print("ERROR: expected type \(P.self), got \(Swift.type(of: decoded))")
        throw PolyFactoryError.unexpectedType
    }
}

public enum PolyFactoryError: Error {
    case unexpectedType
    case unknownTypeName(String)
}

extension PolySerializable {
    /// Encode a `PolySerializable` to a JSON string, embedding its `kind`.
    func toJSON() throws -> String {
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
        let concreteType = try PolyFactory.decodableType(kind: kind)
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
