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

//extension PolySerializable {
//    init(encodedJSON: String?) throws {
//        self = try PolyFactory.make(kind: Self.kind, encodedJSON: encodedJSON) as! Self
//    }
//}

final class PolyFactory {
    static func make(kind: UInt, encodedJSON: String?) throws -> PolySerializable {
        switch kind {

        case RootNode.kind: return try RootNode.fromJSONString(encodedJSON)
        case CommandInterpreter.kind: return try CommandInterpreter.fromJSONString(encodedJSON)
        case FormulaFinder.kind: return try FormulaFinder.fromJSONString(encodedJSON)
        case FormulaExtractor.kind: return try FormulaExtractor.fromJSONString(encodedJSON)
        case BuildGraph.kind: return try BuildGraph.fromJSONString(encodedJSON)
        case StaticFileNode.kind: return try StaticFileNode.fromJSONString(encodedJSON)
        case FolderNode.kind: return try FolderNode.fromJSONString(encodedJSON)
        case FolderEvent.kind: return try FolderEvent.fromJSONString(encodedJSON)

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

private struct Cassette: Codable {
    enum CodingKeys: CodingKey {
        case kind
        case object
    }

    let object: PolySerializable

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(UInt.self, forKey: .kind)
        let json = try container.decodeIfPresent(String.self, forKey: .object)
        object = try PolyFactory.make(kind: kind, encodedJSON: json)
    }

    init(object: PolySerializable) {
        self.object = object
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type(of: object).kind, forKey: .kind)
        try container.encode(object.asJSONString(), forKey: .object)
    }
}

extension PolySerializable {
    static func fromJSONString(_ string: String?) throws -> Self {
        guard let string else {
            return try .init() // default initializer gives "starting" values to all properties
        }

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

extension PolyFactory {
    static func makeNode(kind: UInt, encodedJSON: String?) throws -> NodeType {
        try make(kind: kind, encodedJSON: encodedJSON) as! NodeType
    }

    static func makeMessage(kind: UInt, encodedJSON: String?) throws -> MessageType {
        try make(kind: kind, encodedJSON: encodedJSON) as! MessageType
    }
}
