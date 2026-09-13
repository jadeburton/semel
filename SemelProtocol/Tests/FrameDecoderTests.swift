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

    func test_rejectsReservedBitsSet() throws {
        var bytes = try FrameEncoder.encode(sample)
        bytes[2] = 0x01
        var decoder = FrameDecoder()
        decoder.append(bytes)

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FrameError, .reservedBitsSet(flags: 1, reserved: 0))
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

    // MARK: - Helpers

    private func bigEndianBytes<Integer: FixedWidthInteger>(of value: Integer) -> Data {
        var data = Data()
        data.appendBigEndian(value)
        return data
    }
}
