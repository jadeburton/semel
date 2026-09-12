// FrameEncoder.swift
// SemelProtocol
//
// Frame → bytes. The layout is documented on `Frame`.

import Foundation

public enum FrameEncoder {

    public static func encode(_ frame: Frame) -> Data {
        var bytes = Data(capacity: Frame.headerLength + frame.json.count + frame.body.count)

        bytes.append(Frame.version)
        bytes.append(frame.kind.rawValue)
        bytes.append(0)     // flags
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
