// MessageCoder.swift
// SemelProtocol
//
// The one JSON configuration both ends use. Keys are sorted so that the same message
// always produces the same bytes — which is what lets a test assert the wire text
// literally, and what will let a cache key over a message be stable if one is ever wanted.

import Foundation

public enum MessageCoder {

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    public static func encode<Message: Encodable>(_ message: Message) throws -> Data {
        try encoder.encode(message)
    }

    public static func decode<Message: Decodable>(_ type: Message.Type, from data: Data) throws -> Message {
        try decoder.decode(type, from: data)
    }
}
