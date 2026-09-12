// Frame.swift
// SemelProtocol
//
// The unit of transmission. Every frame carries a JSON section and a raw body, either of
// which may be empty, so that a message with bytes attached (a pushed file, a fetched
// artifact) is one frame rather than two tied by correlation ID with the failure mode of
// one arriving without the other.
//
//   offset  size  field
//     0      1    version
//     1      1    kind            1=request 2=response 3=event
//     2      1    flags           reserved (chunking, compression)
//     3      1    reserved
//     4      8    correlationID   echoed in the response; 0 for events
//    12      4    jsonLength
//    16      8    bodyLength
//    24      …    json bytes
//     …      …    body bytes
//
// All integers big-endian. No magic bytes: the transport already gives ordered,
// integrity-checked delivery, and a desync would be our own framing bug. The message type
// is not in the header either — it is the enum case inside the JSON, and a second
// discriminator would be two sources of truth for one question.

import Foundation

public enum FrameKind: UInt8 {
    case request  = 1
    case response = 2
    case event    = 3
}

public struct Frame: Equatable {

    /// Governs *framing* and is checked before anything is decoded. A mismatch closes the
    /// connection, because nothing further can be trusted. The message set has its own
    /// version, negotiated in `Hello` once framing is known to work.
    public static let version: UInt8 = 1

    public static let headerLength = 24

    /// Enforced by the decoder before allocation, so a corrupt or hostile length cannot
    /// ask for memory the process does not have.
    public static let maximumJSONLength: UInt32 = 1 << 20
    public static let maximumBodyLength: UInt64 = 512 << 20

    public let kind:          FrameKind
    public let correlationID: UInt64
    public let json:          Data
    public let body:          Data

    public init(kind: FrameKind, correlationID: UInt64, json: Data, body: Data = Data()) {
        self.kind          = kind
        self.correlationID = correlationID
        self.json          = json
        self.body          = body
    }
}

public enum FrameError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion(UInt8)
    case unknownKind(UInt8)
    case jsonTooLarge(declared: UInt32, limit: UInt32)
    case bodyTooLarge(declared: UInt64, limit: UInt64)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "frame version \(version) is not supported; this end speaks version \(Frame.version)"
        case .unknownKind(let kind):
            return "frame kind \(kind) is not request, response or event"
        case .jsonTooLarge(let declared, let limit):
            return "frame declares \(declared) bytes of JSON; the limit is \(limit)"
        case .bodyTooLarge(let declared, let limit):
            return "frame declares \(declared) bytes of body; the limit is \(limit)"
        }
    }
}
