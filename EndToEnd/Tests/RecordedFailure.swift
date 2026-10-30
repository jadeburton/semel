//
//  RecordedFailure.swift
//  SemelEndToEndTests
//
//  Whether the test being torn down failed, for the roots that are kept only then.
//

import XCTest

extension XCTestCase {

    /// True in `tearDown` when the test recorded a failure: an assertion that failed or
    /// an error it threw. Read from the run's failure count, because
    /// `XCTestRun.hasSucceeded` answers for the run as a whole and is false until the run
    /// has ended.
    var hasRecordedFailure: Bool { (testRun?.totalFailureCount ?? 0) > 0 }
}
