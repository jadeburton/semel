//
//  DebugTests.swift
//  SemelNodeKitTests
//
//  What `Debug.log` costs when nobody is reading.
//
//  The point of this facility is that it can be used freely, and that only holds if a call
//  costs nothing when it is switched off. The expensive half of a log line is usually the
//  string it builds, not the printing — so what has to be true is that the message is never
//  *constructed* unless something will read it. These tests assert that directly, by counting
//  how often the autoclosure runs.
//

@testable import SemelNodeKit
import XCTest

final class DebugTests: XCTestCase {

    private var wasEnabled = true

    override func setUp() {
        super.setUp()
        wasEnabled = Debug.isEnabled
    }

    override func tearDown() {
        Debug.isEnabled = wasEnabled
        super.tearDown()
    }

    /// The assertion the whole design rests on: switched off, the message is not built. A
    /// caller interpolating a node count, a path, or an elapsed time pays nothing for it.
    func test_theMessageIsNotBuiltWhenLoggingIsOff() {
        Debug.isEnabled = false
        var built = 0

        Debug.log(self.expensiveMessage(counting: &built))

        XCTAssertEqual(built, 0, "the autoclosure ran despite logging being off")
    }

    /// The other side of it, so the test above cannot pass by the call doing nothing at all.
    func test_theMessageIsBuiltWhenLoggingIsOn() {
        Debug.isEnabled = true
        var built = 0

        Debug.log(self.expensiveMessage(counting: &built))

        #if DEBUG
        XCTAssertEqual(built, 1)
        #else
        XCTAssertEqual(built, 0, "a release build should not build the message either")
        #endif
    }

    /// Silencing is a property of the run, not of a call site, so it holds until put back.
    func test_theFlagPersistsAcrossCalls() {
        Debug.isEnabled = false
        var built = 0

        Debug.log(self.expensiveMessage(counting: &built))
        Debug.log(self.expensiveMessage(counting: &built))

        XCTAssertEqual(built, 0)
    }

    private func expensiveMessage(counting built: inout Int) -> String {
        built += 1
        return "a message that cost something to make"
    }
}
