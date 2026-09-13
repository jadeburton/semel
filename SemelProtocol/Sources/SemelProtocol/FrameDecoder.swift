// FrameDecoder.swift
// SemelProtocol
//
// Bytes → frames, incrementally. Feed it whatever the transport delivered and ask for the
// next complete frame; it answers nil until one is whole.
//
// The header is validated the moment it is complete, before the JSON and body bytes have
// arrived. That ordering is the point: a declared length is checked against the limit
// while it is still just a number, never after it has been used to reserve memory.

import Foundation

public struct FrameDecoder {

    // ISSUE: peak memory is about twice a large frame, because the body is copied out of
    // `buffer` into the `Frame` while `buffer` still holds it, and `removeFirst` below is
    // O(remaining) per frame. Measure both against a real socket in phase 3 before
    // restructuring either.
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(contentsOf: bytes)
    }

    /// The next complete frame, or nil if more bytes are needed. Throws on a header that
    /// can never become a valid frame; the caller should close the connection, since
    /// nothing after a bad header can be trusted.
    public mutating func next() throws -> Frame? {
        guard buffer.count >= Frame.headerLength else {
            return nil
        }

        let version = buffer[0]
        guard version == Frame.version else {
            throw FrameError.unsupportedVersion(version)
        }

        guard let kind = FrameKind(rawValue: buffer[1]) else {
            throw FrameError.unknownKind(buffer[1])
        }

        // A reserved bit is reserved for a meaning this build does not know. Honoring the
        // frame as if the bit were clear would hand up wrong data silently; rejecting is the
        // only safe reading, and it is cheapest to establish now, before any peer exists to
        // depend on the alternative.
        guard buffer[2] == 0, buffer[3] == 0 else {
            throw FrameError.reservedBitsSet(flags: buffer[2], reserved: buffer[3])
        }

        let correlationID = readBigEndian(UInt64.self, at: 4)
        let jsonLength    = readBigEndian(UInt32.self, at: 12)
        let bodyLength    = readBigEndian(UInt64.self, at: 16)

        guard jsonLength <= Frame.maximumJSONLength else {
            throw FrameError.jsonTooLarge(declared: jsonLength, limit: Frame.maximumJSONLength)
        }
        guard bodyLength <= Frame.maximumBodyLength else {
            throw FrameError.bodyTooLarge(declared: bodyLength, limit: Frame.maximumBodyLength)
        }

        let jsonStart = Frame.headerLength
        let bodyStart = jsonStart + Int(jsonLength)
        let frameEnd  = bodyStart + Int(bodyLength)

        guard buffer.count >= frameEnd else {
            return nil
        }

        let frame = Frame(kind:          kind,
                          correlationID: correlationID,
                          json:          Data(buffer[jsonStart..<bodyStart]),
                          body:          Data(buffer[bodyStart..<frameEnd]))

        buffer.removeFirst(frameEnd)
        return frame
    }

    private func readBigEndian<Integer: FixedWidthInteger>(_ type: Integer.Type, at offset: Int) -> Integer {
        var value: Integer = 0
        for index in 0..<MemoryLayout<Integer>.size {
            value = value << 8 | Integer(buffer[offset + index])
        }
        return value
    }
}
