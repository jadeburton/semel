//
//  MessageJSONTests.swift
//  SemelProtocolTests
//
//  The JSON text is the contract with a future peer, so representative messages are
//  asserted as exact text and not only by round trip. Keys are sorted, so the text is
//  stable across runs and the assertions can be literal.
//

@testable import SemelProtocol
import XCTest

final class MessageJSONTests: XCTestCase {

    // MARK: - Hello

    func test_encodesHelloAsRoleAndVersion() throws {
        let hello = Hello(protocolVersion: 1, role: .daemon)

        XCTAssertEqual(try json(hello), #"{"protocolVersion":1,"role":"daemon"}"#)
    }

    func test_encodesAcceptedHelloResponse() throws {
        let response = HelloResponse.accepted(serverVersion: "0.9", databasePath: "/tmp/graph.sqlite")

        XCTAssertEqual(try json(response),
                       #"{"accepted":{"databasePath":"\/tmp\/graph.sqlite","serverVersion":"0.9"}}"#)
    }

    func test_encodesRejectedHelloResponse() throws {
        let response = HelloResponse.rejected(reason: .versionMismatch(client: 1, server: 2))

        XCTAssertEqual(try json(response),
                       #"{"rejected":{"reason":{"versionMismatch":{"client":1,"server":2}}}}"#)
    }

    func test_roundTripsEveryHelloRejection() throws {
        let rejections: [HelloRejection] = [
            .versionMismatch(client: 1, server: 2),
            .roleNotOffered(role: .cache),
        ]
        for rejection in rejections {
            XCTAssertEqual(try roundTrip(HelloResponse.rejected(reason: rejection)),
                           .rejected(reason: rejection))
        }
    }

    func test_currentProtocolVersionIsOne() {
        XCTAssertEqual(ProtocolVersion.current, 1)
    }

    // MARK: - Helpers

    func json<Message: Encodable>(_ message: Message) throws -> String {
        String(decoding: try MessageCoder.encode(message), as: UTF8.self)
    }

    func roundTrip<Message: Codable>(_ message: Message) throws -> Message {
        try MessageCoder.decode(Message.self, from: try MessageCoder.encode(message))
    }
}
