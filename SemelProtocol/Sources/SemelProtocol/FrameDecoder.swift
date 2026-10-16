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

    /// The body length from which a frame's body is received into a mapping of its own
    /// (`MappedBody`) rather than through `buffer`.
    static let mappedBodyLength = 1 << 20

    /// What has arrived and is not yet part of a frame handed over, or of the mapped body
    /// being filled.
    private var buffer: [UInt8] = []

    /// A frame whose header and JSON have arrived and whose large body is arriving.
    private var receiving: ReceivingFrame?

    public init() {}

    /// What the buffer holds room for: what a test reads to see that a large frame's room
    /// is not kept once the frame has gone.
    var bufferCapacity: Int {
        buffer.capacity
    }

    public mutating func append(_ bytes: Data) {
        guard let receiving, !receiving.body.isFull else {
            buffer.append(contentsOf: bytes)
            return
        }
        let taken = bytes.withUnsafeBytes { receiving.body.fill(from: $0) }
        if taken < bytes.count {
            buffer.append(contentsOf: bytes.dropFirst(taken))
        }
    }

    /// The next complete frame, or nil if more bytes are needed. Throws on a header that
    /// can never become a valid frame; the caller should close the connection, since
    /// nothing after a bad header can be trusted.
    public mutating func next() throws -> Frame? {
        if let receiving {
            guard receiving.body.isFull else {
                return nil
            }
            self.receiving = nil
            return receiving.frame()
        }

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
        guard buffer[2] & ~Frame.continuesFlag == 0, buffer[3] == 0 else {
            throw FrameError.reservedBitsSet(flags: buffer[2], reserved: buffer[3])
        }
        let continues = buffer[2] & Frame.continuesFlag != 0

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

        if Int(bodyLength) >= Self.mappedBodyLength {
            guard buffer.count >= bodyStart else {
                return nil
            }
            let body = try MappedBody(length: Int(bodyLength))
            let arrived = min(buffer.count, frameEnd)
            buffer[bodyStart..<arrived].withUnsafeBytes { body.fill(from: $0) }
            let frame = ReceivingFrame(kind: kind, correlationID: correlationID,
                                       json: Data(buffer[jsonStart..<bodyStart]), continues: continues, body: body)
            takeFromBuffer(upTo: arrived)
            guard body.isFull else {
                receiving = frame
                return nil
            }
            return frame.frame()
        }

        guard buffer.count >= frameEnd else {
            return nil
        }

        let frame = Frame(kind:          kind,
                          correlationID: correlationID,
                          json:          Data(buffer[jsonStart..<bodyStart]),
                          body:          Data(buffer[bodyStart..<frameEnd]),
                          continues:     continues)
        takeFromBuffer(upTo: frameEnd)
        return frame
    }

    /// Drops what the buffer holds before `end`, leaving the rest in a buffer of its own
    /// size. `removeFirst` would keep the room the largest frame needed, written and so
    /// resident, for as long as the connection lasts.
    private mutating func takeFromBuffer(upTo end: Int) {
        buffer = end == buffer.count ? [] : Array(buffer[end...])
    }

    private func readBigEndian<Integer: FixedWidthInteger>(_ type: Integer.Type, at offset: Int) -> Integer {
        var value: Integer = 0
        for index in 0..<MemoryLayout<Integer>.size {
            value = value << 8 | Integer(buffer[offset + index])
        }
        return value
    }
}

// MARK: - A large body

/// A frame whose large body is arriving into its mapping.
private struct ReceivingFrame {
    let kind:          FrameKind
    let correlationID: UInt64
    let json:          Data
    let continues:     Bool
    let body:          MappedBody

    func frame() -> Frame {
        Frame(kind: kind, correlationID: correlationID, json: json, body: body.handOver(), continues: continues)
    }
}

/// A large frame body, received straight into anonymous memory mapped for it alone and
/// handed over as the frame's `Data` without a copy; unmapped when the last `Data` holding
/// it goes, or here if it never completes.
///
/// Neither copied nor allocated by malloc, and that is the reason for it. A body read
/// through the buffer is held twice at its peak, in the buffer and in the copy the frame
/// takes; and malloc keeps a large block it is given back, dirty and resident, for the
/// next allocation of its size. A push of Sequel Ace's clone, whose vendored binaries go as
/// bodies of up to 68 MB, left 616 MB of such blocks in the server's footprint against
/// 12 MB live, and `malloc_zone_pressure_relief` released none of them. A mapping goes
/// back to the system when it is unmapped.
///
/// A class, because it owns the mapping until the frame takes it.
private final class MappedBody {
    let length: Int
    private let start: UnsafeMutableRawPointer
    private var filled = 0
    private var handedOver = false

    init(length: Int) throws {
        guard let mapping = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              mapping != MAP_FAILED else {
            throw FrameError.bodyNotMapped(length: length, errorNumber: errno)
        }
        self.length = length
        self.start  = mapping
    }

    deinit {
        if !handedOver {
            munmap(start, length)
        }
    }

    var isFull: Bool {
        filled == length
    }

    /// Copies in as many of `bytes` as the body still lacks, and says how many that was.
    @discardableResult
    func fill(from bytes: UnsafeRawBufferPointer) -> Int {
        let taken = min(bytes.count, length - filled)
        if let source = bytes.baseAddress, taken > 0 {
            (start + filled).copyMemory(from: source, byteCount: taken)
        }
        filled += taken
        return taken
    }

    /// The body as `Data` that unmaps it when released. Once only: the mapping is the
    /// `Data`'s from here.
    func handOver() -> Data {
        handedOver = true
        return Data(bytesNoCopy: start, count: length, deallocator: .custom { pointer, length in
            munmap(pointer, length)
        })
    }
}
