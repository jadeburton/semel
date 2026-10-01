//
//  FrameEncoderTests.swift
//  SemelProtocolTests
//
//  The header layout is the contract with every future peer, so it is asserted byte by
//  byte rather than only by round trip: a round trip would pass if both ends made the
//  same mistake.
//
//  There is no body-limit test here: a frame that actually exceeds `maximumBodyLength`
//  would need to allocate 512 MB just to build. `test_refusesJSONOverTheLimit` exercises
//  the same guard on the cheaper JSON side.
//

@testable import SemelProtocol
import XCTest

final class FrameEncoderTests: XCTestCase {

    func test_encodesHeaderFieldsBigEndianInSpecifiedOrder() throws {
        let frame = Frame(kind:          .response,
                          correlationID: 0x0102030405060708,
                          json:          Data("{}".utf8),
                          body:          Data([0xAA, 0xBB, 0xCC]))

        let bytes = [UInt8](try FrameEncoder.encode(frame))

        XCTAssertEqual(bytes.count, Frame.headerLength + 2 + 3)
        XCTAssertEqual(bytes[0], Frame.version)
        XCTAssertEqual(bytes[1], FrameKind.response.rawValue)
        XCTAssertEqual(bytes[2], 0)                                        // flags
        XCTAssertEqual(bytes[3], 0)                                        // reserved
        XCTAssertEqual(Array(bytes[4..<12]),  [1, 2, 3, 4, 5, 6, 7, 8])    // correlationID
        XCTAssertEqual(Array(bytes[12..<16]), [0, 0, 0, 2])                // jsonLength
        XCTAssertEqual(Array(bytes[16..<24]), [0, 0, 0, 0, 0, 0, 0, 3])    // bodyLength
        XCTAssertEqual(Array(bytes[24..<26]), [UInt8]("{}".utf8))
        XCTAssertEqual(Array(bytes[26..<29]), [0xAA, 0xBB, 0xCC])
    }

    func test_encodesEmptySectionsAsHeaderOnly() throws {
        let frame = Frame(kind: .event, correlationID: 0, json: Data(), body: Data())

        XCTAssertEqual(try FrameEncoder.encode(frame).count, Frame.headerLength)
    }

    /// A part of a streamed reply says so in flag bit 0 and nowhere else; every other
    /// frame leaves the byte zero.
    func test_aContinuingFrameSetsFlagBitZero() throws {
        let part = Frame(kind: .response, correlationID: 9, json: Data("{}".utf8), continues: true)
        let last = Frame(kind: .response, correlationID: 9, json: Data("{}".utf8))

        XCTAssertEqual([UInt8](try FrameEncoder.encode(part))[2], 0x01)
        XCTAssertEqual([UInt8](try FrameEncoder.encode(last))[2], 0x00)
    }

    func test_bodyDefaultsToEmpty() {
        let frame = Frame(kind: .request, correlationID: 7, json: Data("{}".utf8))

        XCTAssertEqual(frame.body, Data())
    }

    // MARK: - Rejection

    func test_refusesJSONOverTheLimit() {
        let frame = Frame(kind: .request,
                          correlationID: 1,
                          json:          Data(count: Int(Frame.maximumJSONLength) + 1))

        XCTAssertThrowsError(try FrameEncoder.encode(frame)) { error in
            XCTAssertEqual(error as? FrameError,
                           .jsonTooLarge(declared: Frame.maximumJSONLength + 1, limit: Frame.maximumJSONLength))
        }
    }
}
