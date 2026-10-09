//
//  StreamedReplyTests.swift
//  SemelProtocolTests
//
//  A reply in parts (B-137), read as a client reads it: frame by frame, with the parts
//  joined in the order they came. What is pinned: a part is told from the last by the
//  flag alone, a stream cut off by a closing connection is reported as cut off rather
//  than as an answer, and only the three cases that may stream are accepted as parts.
//

@testable import SemelProtocol
import XCTest

final class StreamedReplyTests: XCTestCase {

    private func part(_ response: DaemonResponse, correlationID: UInt64 = 4) throws -> Frame {
        try Frame.response(.daemon(response), correlationID: correlationID, continues: true)
    }

    private func last(_ response: Response, correlationID: UInt64 = 4) throws -> Frame {
        try Frame.response(response, correlationID: correlationID)
    }

    // MARK: - Frame by frame

    func test_aContinuingFrameIsAPartAndTheUnmarkedOneIsTheLast() throws {
        var reply = IncomingReply(correlationID: 4)

        let first  = try reply.receive(try part(.remove(removedFiles: ["a"], removedFolders: [])))
        let ending = try reply.receive(try last(.daemon(.remove(removedFiles: ["b"], removedFolders: []))))

        XCTAssertEqual(first, .part(.daemon(.remove(removedFiles: ["a"], removedFolders: []))))
        XCTAssertEqual(ending, .last(.daemon(.remove(removedFiles: ["b"], removedFolders: [])), body: nil))
        XCTAssertEqual(reply.partsReceived, 1)
    }

    /// A frame with the bit set and nothing after it, then the connection closes: the
    /// reply is reported as truncated, naming the request and how much came, never handed
    /// over as though the part were the answer.
    func test_aStreamWithNoLastFrameIsTruncatedWhenTheConnectionCloses() throws {
        var reply = IncomingReply(correlationID: 4)
        _ = try reply.receive(try part(.list(entries: [])))
        _ = try reply.receive(try part(.list(entries: [])))

        XCTAssertEqual(reply.truncation, .truncated(correlationID: 4, partsReceived: 2))
    }

    /// Closing before any frame of the reply came is the connection's own failure, not a
    /// stream cut short, and the connection says it in its own words.
    func test_aReplyThatNeverBeganIsNotTruncated() {
        XCTAssertNil(IncomingReply(correlationID: 4).truncation)
    }

    /// A server that marks a single-frame reply as continuing would have a waiter take a
    /// part for the whole; the client refuses it.
    func test_aPartOfACaseThatNeverStreamsIsRefused() throws {
        var reply = IncomingReply(correlationID: 4)

        XCTAssertThrowsError(try reply.receive(try part(.ok))) { error in
            XCTAssertEqual(error as? ReplyStreamError, .notStreamable)
        }
    }

    // MARK: - Joined

    func test_partsJoinInOrderWithTheLast() throws {
        var parts = ReplyParts()
        try parts.append(.daemon(.remove(removedFiles: ["a", "b"], removedFolders: ["x"])))
        try parts.append(.daemon(.remove(removedFiles: ["c"], removedFolders: [])))

        let whole = try parts.whole(endingWith: .daemon(.remove(removedFiles: ["d"], removedFolders: ["y"])))

        XCTAssertEqual(whole, .daemon(.remove(removedFiles: ["a", "b", "c", "d"], removedFolders: ["x", "y"])))
    }

    /// A server that learns it is done only after its last item ends with an empty slice.
    func test_anEmptyLastSliceEndsTheStream() throws {
        var parts = ReplyParts()
        try parts.append(.daemon(.errors(records: [ErrorRecord(document: .engine(.noSources, subject: nil), products: [],
                                                                                   facts: ErrorFacts(nodeType: "a", nodeIDs: [1], ports: [],
                                                                                                     carrierCount: 0))])))

        let whole = try parts.whole(endingWith: .daemon(.errors(records: [])))

        XCTAssertEqual(whole, .daemon(.errors(records: [ErrorRecord(document: .engine(.noSources, subject: nil), products: [],
                                                                                   facts: ErrorFacts(nodeType: "a", nodeIDs: [1], ports: [],
                                                                                                     carrierCount: 0))])))
    }

    /// With no parts the last frame is the reply as it came: a small reply is untouched.
    func test_aReplyWithNoPartsIsItsLastFrame() throws {
        XCTAssertEqual(try ReplyParts().whole(endingWith: .daemon(.ok)), .daemon(.ok))
    }

    /// The request failed after some of its answer had gone: the error is the reply.
    func test_anErrorThatEndsAStreamIsTheReply() throws {
        var parts = ReplyParts()
        try parts.append(.daemon(.remove(removedFiles: ["a"], removedFolders: [])))

        let whole = try parts.whole(endingWith: .error(.nodeError(description: "Child not deletable: b")))

        XCTAssertEqual(whole, .error(.nodeError(description: "Child not deletable: b")))
    }

    func test_partsOfDifferentCasesDoNotJoin() throws {
        var parts = ReplyParts()
        try parts.append(.daemon(.list(entries: [])))

        XCTAssertThrowsError(try parts.append(.daemon(.errors(records: [])))) { error in
            XCTAssertEqual(error as? ReplyStreamError, .mismatchedPart)
        }
        XCTAssertThrowsError(try parts.whole(endingWith: .daemon(.remove(removedFiles: [], removedFolders: [])))) { error in
            XCTAssertEqual(error as? ReplyStreamError, .mismatchedPart)
        }
    }

    func test_onlyListRemoveAndErrorsMayStream() {
        let streaming: [DaemonResponse] = [.list(entries: []), .remove(removedFiles: [], removedFolders: []),
                                           .errors(records: [])]
        let single: [DaemonResponse] = [.ok, .pushFile(didChange: true), .pushFiles(outcomes: []), .contentRoots, .folderChildren,
                                        .fetch(mode: 0o644), .symbolicLink(target: "a"), .check(scheduledNodes: 0),
                                        .collected(removed: 0, removedBytes: 0, kept: 0), .tools(namespaces: []),
                                        .reset(archivedGraphPath: nil), .explain(explanation: nil), .debug]

        XCTAssertTrue(streaming.allSatisfy(\.mayStream))
        XCTAssertFalse(single.contains(where: \.mayStream))
    }
}
