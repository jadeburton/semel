//
//  HandleCommandResultTests.swift
//  SemelCLITests
//

@testable import SemelCLI
import Foundation
import XCTest

/// `handleCommand` tells its caller what one line came to, so the loop feeding it commands
/// reads the exit condition from a value rather than from a thrown error.
final class HandleCommandResultTests: XCTestCase {

    private var interpreter: CommandInterpreter!

    override func setUp() {
        super.setUp()
        interpreter = CommandInterpreter(connection: RecordingConnection(), baseDirectory: "/")
    }

    func test_aCommandThatReportsNothingSucceeds() {
        XCTAssertEqual(interpreter.handleCommand("pwd"), .success)
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_aCommandThatReportsAnErrorFails() {
        XCTAssertEqual(interpreter.handleCommand("frobnicate"), .failed)
        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    func test_quitEndsTheSessionWithoutCountingAnError() {
        XCTAssertEqual(interpreter.handleCommand("quit"), .quit)
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_anEmptyLineSucceeds() {
        XCTAssertEqual(interpreter.handleCommand("   "), .success)
    }
}
