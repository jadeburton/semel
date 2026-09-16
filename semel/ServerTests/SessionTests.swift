//
//  SessionTests.swift
//  SemelServerTests
//
//  Per-connection state. The one rule worth a test: batches are counted, so a session
//  torn down mid-push can be unwound exactly as many times as it was opened.
//

@testable import SemelServer
import XCTest

final class SessionTests: XCTestCase {

    func test_startsUnsubscribedWithNoOpenBatch() {
        let session = Session()

        XCTAssertFalse(session.isSubscribed)
        XCTAssertEqual(session.openBatchDepth, 0)
    }

    func test_countsNestedBatches() {
        let session = Session()

        session.batchOpened()
        session.batchOpened()
        session.batchClosed()

        XCTAssertEqual(session.openBatchDepth, 1)
    }

    func test_closingBelowZeroIsIgnored() {
        let session = Session()

        session.batchClosed()

        XCTAssertEqual(session.openBatchDepth, 0)
    }
}
