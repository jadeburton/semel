//
//  HandleCommandResultTests.swift
//  SemelCLITests
//

@testable import SemelCLI
import Foundation
import SemelProtocol
import XCTest

/// A connection that fails every send, so the interpreter's catch-all reporting path runs.
private final class FailingConnection: SemelConnection {

    var onEvent: ((Event) -> Void)?

    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func send(_ request: Request, body: Data?) throws -> (Response, Data?) {
        throw error
    }
}

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

    // MARK: - What a failure says

    /// B-94. A command that throws is reported through the same path whatever it threw, and
    /// counted once.
    func test_aCommandWhoseConnectionFailsReportsItOnce() {
        let failing = CommandInterpreter(connection: FailingConnection(error: ConnectionError.closed),
                                         baseDirectory: "/")

        XCTAssertEqual(failing.handleCommand("debug"), .failed)
        XCTAssertEqual(failing.errorsReported, 1)
    }

    /// And what that path shows is what the error says about itself. `localizedDescription`,
    /// the other way to ask, answers for a Swift error only when it conforms to
    /// `LocalizedError`; for every other one it is "The operation couldn't be completed.
    /// (SemelCLI.ConnectError error 0.)", which is what a protocol version mismatch, a
    /// misplaced frame and a decoding failure all look like at the prompt.
    func test_aThrownErrorIsShownAsWhatItSaysAboutItself() {
        XCTAssertEqual(CommandInterpreter.userFacingMessage(for: ConnectError.rejected(.versionMismatch(client: 1, server: 2))),
                       "this semel speaks protocol version 1 but the server speaks 2")

        let misplacedFrame = CommandInterpreter.userFacingMessage(
            for: MessageError.wrongKind(expected: .response, actual: .event))
        XCTAssertTrue(misplacedFrame.contains("frame"), misplacedFrame)
        XCTAssertFalse(misplacedFrame.contains("couldn't be completed"), misplacedFrame)
    }
}
