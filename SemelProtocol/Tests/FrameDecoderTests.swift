//
//  FrameDecoderTests.swift
//  SemelProtocolTests
//
//  A socket delivers whatever it delivers: half a header, three frames at once, a body
//  split across reads. The decoder has to be happy with all of it, and it has to refuse
//  an over-limit length before allocating anything, because a declared length is the one
//  field a corrupt or hostile peer controls directly.
//

@testable import SemelProtocol
import XCTest

final class FrameDecoderTests: XCTestCase {

    private let sample = Frame(kind:          .request,
                               correlationID: 42,
                               json:          Data(#"{"hello":{}}"#.utf8),
                               body:          Data([1, 2, 3, 4, 5]))

    // MARK: - Whole frames

    func test_roundTripsAFrame() throws {
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(sample))

        XCTAssertEqual(try decoder.next(), sample)
        XCTAssertNil(try decoder.next())
    }

    func test_roundTripsAHeaderOnlyFrame() throws {
        let empty = Frame(kind: .event, correlationID: 0, json: Data(), body: Data())
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(empty))

        XCTAssertEqual(try decoder.next(), empty)
    }

    /// The continue flag survives the trip, and two frames of one stream stay two frames
    /// with one correlation ID, the first marked and the second not.
    func test_roundTripsTheContinueFlag() throws {
        let part = Frame(kind: .response, correlationID: 7, json: Data("{}".utf8), continues: true)
        let last = Frame(kind: .response, correlationID: 7, json: Data("{}".utf8))
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(part) + FrameEncoder.encode(last))

        let first  = try XCTUnwrap(try decoder.next())
        let second = try XCTUnwrap(try decoder.next())

        XCTAssertEqual(first, part)
        XCTAssertTrue(first.continues)
        XCTAssertEqual(second, last)
        XCTAssertFalse(second.continues)
    }

    func test_yieldsTwoFramesFromOneAppend() throws {
        let second = Frame(kind: .response, correlationID: 43, json: Data("{}".utf8))
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(sample) + FrameEncoder.encode(second))

        XCTAssertEqual(try decoder.next(), sample)
        XCTAssertEqual(try decoder.next(), second)
        XCTAssertNil(try decoder.next())
    }

    // MARK: - Partial delivery

    func test_waitsWhenHeaderIsIncomplete() throws {
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(sample).prefix(Frame.headerLength - 1))

        XCTAssertNil(try decoder.next())
    }

    func test_waitsWhenBodyIsIncomplete() throws {
        let bytes = try FrameEncoder.encode(sample)
        var decoder = FrameDecoder()
        decoder.append(bytes.prefix(bytes.count - 1))

        XCTAssertNil(try decoder.next())
    }

    func test_assemblesAFrameDeliveredOneByteAtATime() throws {
        var decoder = FrameDecoder()
        for byte in try FrameEncoder.encode(sample) {
            XCTAssertNil(try decoder.next())
            decoder.append(Data([byte]))
        }

        XCTAssertEqual(try decoder.next(), sample)
    }

    // MARK: - Rejection, before allocation

    func test_rejectsAnUnsupportedVersion() throws {
        var bytes = try FrameEncoder.encode(sample)
        bytes[0] = Frame.version + 1
        var decoder = FrameDecoder()
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError, .unsupportedVersion(Frame.version + 1))
        }
    }

    func test_rejectsAnUnknownKind() throws {
        var bytes = try FrameEncoder.encode(sample)
        bytes[1] = 9
        var decoder = FrameDecoder()
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError, .unknownKind(9))
        }
    }

    /// Bit 0 of the flags is the continue flag; the seven above it are still reserved.
    func test_rejectsReservedBitsSet() throws {
        var bytes = try FrameEncoder.encode(sample)
        bytes[2] = 0x03
        var decoder = FrameDecoder()
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError, .reservedBitsSet(flags: 3, reserved: 0))
        }
    }

    func test_rejectsTheReservedByteSet() throws {
        var bytes = try FrameEncoder.encode(sample)
        bytes[3] = 0x01
        var decoder = FrameDecoder()
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError, .reservedBitsSet(flags: 0, reserved: 1))
        }
    }

    /// Only the header is present, so a decoder that waited for the declared bytes before
    /// checking the limit would wait forever — or, worse, reserve room for them.
    func test_rejectsAnOversizedJSONLengthFromTheHeaderAlone() throws {
        var bytes = try FrameEncoder.encode(sample).prefix(Frame.headerLength)
        let declared = Frame.maximumJSONLength + 1
        bytes.replaceSubrange(12..<16, with: bigEndianBytes(of: declared))
        var decoder = FrameDecoder()
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError,
                           .jsonTooLarge(declared: declared, limit: Frame.maximumJSONLength))
        }
    }

    func test_rejectsAnOversizedBodyLengthFromTheHeaderAlone() throws {
        var bytes = try FrameEncoder.encode(sample).prefix(Frame.headerLength)
        let declared = Frame.maximumBodyLength + 1
        bytes.replaceSubrange(16..<24, with: bigEndianBytes(of: declared))
        var decoder = FrameDecoder()
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError,
                           .bodyTooLarge(declared: declared, limit: Frame.maximumBodyLength))
        }
    }

    func test_acceptsALengthExactlyAtTheLimit() throws {
        let json = Data(repeating: UInt8(ascii: " "), count: Int(Frame.maximumJSONLength))
        let frame = Frame(kind: .request, correlationID: 1, json: json)
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(frame))

        XCTAssertEqual(try decoder.next()?.json.count, Int(Frame.maximumJSONLength))
    }

    // MARK: - The room a large frame needed (B-155)

    /// A frame of 4 MB leaves no room behind once it is taken: a push sends a vendored
    /// binary as one frame, and its session goes on for minutes after.
    func test_aLargeFramesRoomIsNotKeptOnceTaken() throws {
        let large = Frame(kind: .request, correlationID: 9, json: Data("{}".utf8),
                          body: Data(repeating: 7, count: 4 << 20))
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(large))

        XCTAssertEqual(try decoder.next(), large)
        XCTAssertEqual(decoder.bufferCapacity, 0)
    }

    /// The part of the next frame that came with a large one is kept, in room of its own
    /// size, and the frame completes when the rest arrives.
    func test_whatFollowsALargeFrameIsKeptInRoomOfItsOwnSize() throws {
        let large = Frame(kind: .request, correlationID: 9, json: Data("{}".utf8),
                          body: Data(repeating: 7, count: 4 << 20))
        let following = try FrameEncoder.encode(sample)
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(large) + following.prefix(10))

        XCTAssertEqual(try decoder.next(), large)
        XCTAssertNil(try decoder.next())
        XCTAssertLessThan(decoder.bufferCapacity, 1 << 20)

        decoder.append(following.dropFirst(10))
        XCTAssertEqual(try decoder.next(), sample)
    }

    // MARK: - A large body, received into a mapping of its own

    /// A body of `length` bytes that differ from one place to the next, so a byte copied
    /// to the wrong offset is seen.
    private func largeFrame(length: Int = FrameDecoder.mappedBodyLength + 12_345) -> Frame {
        Frame(kind: .request, correlationID: 11, json: Data(#"{"pushFiles":{}}"#.utf8),
              body: Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }))
    }

    /// Delivered in pieces of an odd size, across the header, the JSON and the body, the
    /// frame comes back whole and only once its last byte is in.
    func test_aLargeBodyDeliveredInPiecesComesBackWhole() throws {
        let large   = largeFrame()
        let encoded = try FrameEncoder.encode(large)
        var decoder = FrameDecoder()
        var offset  = 0
        while offset < encoded.count {
            XCTAssertNil(try decoder.next())
            let end = min(offset + 4_099, encoded.count)
            decoder.append(encoded[offset..<end])
            offset = end
        }

        XCTAssertEqual(try decoder.next(), large)
        XCTAssertNil(try decoder.next())
    }

    /// The rest of a large body and the frame after it in one delivery: the body takes
    /// what it lacks and the next frame what follows.
    func test_aLargeBodysLastBytesAndTheNextFrameInOneDelivery() throws {
        let large   = largeFrame()
        let encoded = try FrameEncoder.encode(large)
        var decoder = FrameDecoder()
        decoder.append(encoded.prefix(1_000))
        XCTAssertNil(try decoder.next())

        decoder.append(encoded.dropFirst(1_000) + (try FrameEncoder.encode(sample)))

        XCTAssertEqual(try decoder.next(), large)
        XCTAssertEqual(try decoder.next(), sample)
        XCTAssertNil(try decoder.next())
    }

    /// A body exactly at the length that is mapped, and one a byte short of it, which goes
    /// through the buffer: both come back as sent.
    func test_bodiesEitherSideOfTheMappedLengthComeBackAsSent() throws {
        for length in [FrameDecoder.mappedBodyLength - 1, FrameDecoder.mappedBodyLength] {
            let frame = largeFrame(length: length)
            var decoder = FrameDecoder()
            decoder.append(try FrameEncoder.encode(frame))

            XCTAssertEqual(try decoder.next(), frame, "a body of \(length) bytes")
        }
    }

    /// A decoder dropped while a large body is still arriving gives its mapping back, and
    /// a frame handed over keeps its body after the decoder has gone.
    func test_aLargeBodyOutlivesItsDecoderAndAnUnfinishedOneDoesNot() throws {
        let large = largeFrame()
        var taken: Frame?
        do {
            var decoder = FrameDecoder()
            decoder.append(try FrameEncoder.encode(large))
            taken = try decoder.next()
            decoder.append(try FrameEncoder.encode(large).prefix(Frame.headerLength + 100))
            XCTAssertNil(try decoder.next())
        }

        XCTAssertEqual(taken, large)
    }

    // MARK: - Helpers

    private func bigEndianBytes<Integer: FixedWidthInteger>(of value: Integer) -> Data {
        var data = Data()
        data.appendBigEndian(value)
        return data
    }
}
