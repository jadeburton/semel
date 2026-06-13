//
//  PolyFactory.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

// MARK: - Protocol

/// A type that can be serialized/deserialized polymorphically via a `kind` discriminator.
protocol PolySerializable: Codable {
    static var kind: UInt { get }
}

// MARK: - Factory

/// Creates and serializes `PolySerializable` objects using a kind-based type registry.
enum PolyFactory {

    /// All polymorphic types must be registered here.
    private static let registry: [UInt: PolySerializable.Type] = [
        RootNode.kind:           RootNode.self,
        CommandInterpreter.kind: CommandInterpreter.self,
        FormulaFinder.kind:      FormulaFinder.self,
        FormulaExtractor.kind:   FormulaExtractor.self,
        BuildGraph.kind:         BuildGraph.self,
        StaticFileNode.kind:     StaticFileNode.self,
        FolderNode.kind:         FolderNode.self,
        FolderEvent.kind:        FolderEvent.self,
        ClangLinkerTool.kind:    ClangLinkerTool.self,
        ClangCompilerTool.kind:  ClangCompilerTool.self,
        ClangPreprocessorTool.kind: ClangPreprocessorTool.self,
        FileMetadata.kind:       FileMetadata.self,
        IncludeFinder.kind:      IncludeFinder.self,
        ClangLinkerToolConfiguration.kind:       ClangLinkerToolConfiguration.self,
        ClangCompilerToolConfiguration.kind:     ClangCompilerToolConfiguration.self,
        ClangPreprocessorToolConfiguration.kind: ClangPreprocessorToolConfiguration.self,
        FolderManifest.kind:     FolderManifest.self,
        Schema.kind:             Schema.self
    ]

    /// Look up the concrete type for a given kind.
    static func type(kind: UInt) throws -> PolySerializable.Type {
        guard let type = registry[kind] else {
            fatalError("Unknown object kind: \(kind)")
        }
        return type
    }

    /// Decode a `PolySerializable` from a JSON string that embeds its `kind`.
    static func decode(encodedJSON: String) throws -> any PolySerializable {
        try Cassette.fromJSON(encodedJSON).object
    }

    static func decodeAndCast<P: PolySerializable>(encodedJSON: String) throws -> P {
        let decoded = try decode(encodedJSON: encodedJSON)

        if let object = decoded as? P {
            return object
        }

        print("ERROR: expected type \(P.self), got \(Swift.type(of: decoded))")
        throw PolyFactoryError.unexpectedType
    }
}

enum PolyFactoryError: Error {
    case unexpectedType
}

extension PolySerializable {
    /// Encode a `PolySerializable` to a JSON string, embedding its `kind`.
    func toJSON() throws -> String {
        try Cassette(object: self).toJSON()
    }
}

// MARK: - Cassette (private wrapper that pairs kind + object for serialization)

/// Internal use. Wraps a `PolySerializable` during serialization to add a `kind` discriminator.
private struct Cassette: Codable {

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
        let concreteType = try PolyFactory.type(kind: kind)
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
    static func fromJSON(_ string: String) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(string.utf8))
    }
}

extension Encodable {
    func toJSON() throws -> String {
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
