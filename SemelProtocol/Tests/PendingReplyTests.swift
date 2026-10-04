//
//  PendingReplyTests.swift
//  SemelProtocolTests
//
//  The handle a request sent without waiting returns. What is pinned: the reply is
//  collected once however often it is asked for, a failure is thrown on every ask, and a
//  connection whose `send` answers at once hands back a handle already answered.
//

@testable import SemelProtocol
import XCTest

final class PendingReplyTests: XCTestCase {

    func test_theReplyIsCollectedOnceAndAskedForAgainIsTheSame() throws {
        var collections = 0
        let pending = PendingReply(collecting: {
            collections += 1
            return (.daemon(.ok), Data("body".utf8))
        })

        let first  = try pending.reply()
        let second = try pending.reply()

        XCTAssertEqual(collections, 1)
        XCTAssertEqual(first.0, .daemon(.ok))
        XCTAssertEqual(second.1, Data("body".utf8))
    }

    func test_aFailureIsThrownOnEveryAsk() {
        let pending = PendingReply(collecting: { throw ReplyStreamError.mismatchedPart })

        XCTAssertThrowsError(try pending.reply()) { XCTAssertEqual($0 as? ReplyStreamError, .mismatchedPart) }
        XCTAssertThrowsError(try pending.reply()) { XCTAssertEqual($0 as? ReplyStreamError, .mismatchedPart) }
    }

    /// The protocol's default: `send` runs before the call returns, and a streamed reply is
    /// joined as the whole-reply `send` joins it.
    func test_theDefaultSendsAtOnceAndJoinsAStreamedReply() throws {
        let connection = AnsweringConnection()

        let pending = try connection.sendWithoutWaiting(.daemon(.remove(pattern: "*")), body: nil)

        XCTAssertEqual(connection.sends, 1)
        XCTAssertEqual(try pending.reply().0, .daemon(.remove(removedFiles: ["a", "b"], removedFolders: [])))
        XCTAssertEqual(connection.sends, 1)
    }
}

/// Answers every request with a removal in two parts.
private final class AnsweringConnection: SemelConnection {
    var onEvent: ((Event) -> Void)?
    private(set) var sends = 0

    func send(_ request: Request, body: Data?, onPart: (Response) throws -> Void) throws -> (Response, Data?) {
        sends += 1
        try onPart(.daemon(.remove(removedFiles: ["a"], removedFolders: [])))
        return (.daemon(.remove(removedFiles: ["b"], removedFolders: [])), nil)
    }
}
