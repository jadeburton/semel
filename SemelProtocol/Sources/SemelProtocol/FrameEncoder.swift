// FrameEncoder.swift
// SemelProtocol
//
// Frame → bytes. The layout is documented on `Frame`.

import Foundation

public enum FrameEncoder {

    /// The sender checks the same limits the decoder enforces. A peer that receives an
    /// over-limit frame treats it as a hard failure and closes the connection, so it is
    /// better for the sender to fail locally with a named error than to produce bytes no
    /// peer will accept.
    public static func encode(_ frame: Frame) throws -> Data {
        guard frame.json.count <= Int(Frame.maximumJSONLength) else {
            throw FrameError.jsonTooLarge(declared: UInt32(clamping: frame.json.count), limit: Frame.maximumJSONLength)
        }
        guard frame.body.count <= Int(Frame.maximumBodyLength) else {
            throw FrameError.bodyTooLarge(declared: UInt64(frame.body.count), limit: Frame.maximumBodyLength)
        }

        var bytes = Data(capacity: Frame.headerLength + frame.json.count + frame.body.count)

        bytes.append(Frame.version)
        bytes.append(frame.kind.rawValue)
        bytes.append(frame.continues ? Frame.continuesFlag : 0)
        bytes.append(0)     // reserved
        bytes.appendBigEndian(frame.correlationID)
        bytes.appendBigEndian(UInt32(frame.json.count))
        bytes.appendBigEndian(UInt64(frame.body.count))
        bytes.append(frame.json)
        bytes.append(frame.body)

        return bytes
    }
}

extension Data {

    /// Most-significant byte first, whatever the host's byte order.
    mutating func appendBigEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
