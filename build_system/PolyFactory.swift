//
//  PolyFactory.swift
//  build_system
//
//  Created by Jade Burton on 22.02.26.
//

import Foundation

protocol PolySerializable: AnyObject, Encodable, Decodable {
    static var kind: UInt { get }

    init() throws
}

final class PolyFactory {

    // Construct emtpy object with dynamically determined type
    static func make(kind: UInt) throws -> PolySerializable {
        try type(kind: kind).init()
    }

    // Construct object from JSON string with dynamically determined type embedded within the JSON
    static func make(encodedJSON: String) throws -> PolySerializable {
        try Cassette.fromJSONString(encodedJSON).object
    }

    // Convenience helper
    static func make(kind: UInt, encodedJSON: String?) throws -> NodeType {
        if let encodedJSON  {
            return try make(encodedJSON: encodedJSON) as! NodeType
        } else {
            return try make(kind: kind) as! NodeType
        }
    }

    static func encodeToJSON(_ object: PolySerializable) throws -> String {
        try Cassette(object: object).asJSONString()
    }

    static func type(kind: UInt) throws -> PolySerializable.Type {
        switch kind {

        // All polymorphic types must be added here with their unique kind value
        case RootNode.kind: return RootNode.self
        case CommandInterpreter.kind: return CommandInterpreter.self
        case FormulaFinder.kind: return FormulaFinder.self
        case FormulaExtractor.kind: return FormulaExtractor.self
        case BuildGraph.kind: return BuildGraph.self
        case StaticFileNode.kind: return StaticFileNode.self
        case FolderNode.kind: return FolderNode.self
        case FolderEvent.kind: return FolderEvent.self

        default:
            fatalError("Unknown object kind: \(kind)")
            break
        }
    }

    static func from(bytes: [UInt8]) throws -> PolySerializable {
        let data = Data(bytes)
        let decoder = JSONDecoder()
        let cassette = try decoder.decode(Cassette.self, from: data)
        return cassette.object
    }
}

// Wraps an object during serialization to add a "kind"
private struct Cassette: Codable {
    enum CodingKeys: CodingKey {
        case kind
        case object
    }

    let object: PolySerializable

    init(object: PolySerializable) {
        self.object = object
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(UInt.self, forKey: .kind)
        let type = try PolyFactory.type(kind: kind)
        object = try container.decodeIfPresent(type.self, forKey: .object)!
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type(of: object).kind, forKey: .kind)
        try container.encode(object, forKey: .object)
    }
}

private extension Cassette {
    static func fromJSONString(_ string: String) throws -> Self {
        let decoder = JSONDecoder()
        let data = string.data(using: .utf8)!
        return try decoder.decode(Self.self, from: data)
    }

    func asJSONString() throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8)!
    }
}
