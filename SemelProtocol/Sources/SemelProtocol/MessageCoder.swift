// MessageCoder.swift
// SemelProtocol
//
// The one JSON configuration both ends use. Keys are sorted so that the same message
// always produces the same bytes — which is what lets a test assert the wire text
// literally, and what will let a cache key over a message be stable if one is ever wanted.
// A fresh coder is built per call, because `JSONEncoder` and `JSONDecoder` are mutable
// classes and the callers will be concurrent.

import Foundation

public enum MessageCoder {

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func encode<Message: Encodable>(_ message: Message) throws -> Data {
        try makeEncoder().encode(message)
    }

    public static func decode<Message: Decodable>(_ type: Message.Type, from data: Data) throws -> Message {
        try JSONDecoder().decode(type, from: data)
    }
}
