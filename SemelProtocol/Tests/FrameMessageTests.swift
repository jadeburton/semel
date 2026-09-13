//
//  FrameMessageTests.swift
//  SemelProtocolTests
//
//  The whole path a message takes: typed value → frame → bytes → frame → typed value.
//  This is what phase 2's in-process connection runs every request through, so that the
//  codec is exercised by every CLI test long before a socket exists.
//

@testable import SemelProtocol
import XCTest

final class FrameMessageTests: XCTestCase {

    func test_requestSurvivesTheWholePath() throws {
        let request = Request.daemon(.pushFile(path: "src/a.c", mode: 0o644))
        let body    = Data("int main() {}".utf8)

        let frame = try Frame.request(request, correlationID: 9, body: body)
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(frame))
        let received = try XCTUnwrap(try decoder.next())

        XCTAssertEqual(received.kind, .request)
        XCTAssertEqual(received.correlationID, 9)
        XCTAssertEqual(try received.request(), request)
        XCTAssertEqual(received.body, body)
    }

    func test_responseSurvivesTheWholePath() throws {
        let response = Response.daemon(.fetch(mode: 0o755))
        let body     = Data([0xCA, 0xFE])

        let frame = try Frame.response(response, correlationID: 9, body: body)
        var decoder = FrameDecoder()
        decoder.append(try FrameEncoder.encode(frame))
        let received = try XCTUnwrap(try decoder.next())

        XCTAssertEqual(received.kind, .response)
        XCTAssertEqual(try received.response(), response)
        XCTAssertEqual(received.body, body)
    }

    func test_eventUsesCorrelationIDZero() throws {
        let frame = try Frame.event(.daemon(.notice(line: "hi")))

        XCTAssertEqual(frame.kind, .event)
        XCTAssertEqual(frame.correlationID, 0)
        XCTAssertEqual(try frame.event(), .daemon(.notice(line: "hi")))
    }

    func test_bodyDefaultsToEmpty() throws {
        XCTAssertEqual(try Frame.request(.daemon(.reset), correlationID: 1).body, Data())
    }

    func test_readingTheWrongKindIsAnError() throws {
        let frame = try Frame.request(.daemon(.reset), correlationID: 1)

        XCTAssertThrowsError(try frame.response()) { error in
            XCTAssertEqual(error as? MessageError, .wrongKind(expected: .response, actual: .request))
        }
    }

    func test_undecodableJSONIsAnError() {
        let frame = Frame(kind: .request, correlationID: 1, json: Data("not json".utf8))

        XCTAssertThrowsError(try frame.request())
    }
}
