//
//  HelpTests.swift
//  SemelCLITests
//
//  B-110. `help` names every command; a typo names its nearest one. Neither needs a
//  server, so the connection here answers nothing.
//

@testable import SemelCLI
import XCTest

final class HelpTests: XCTestCase {

    private var interpreter: CommandInterpreter!
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        interpreter = CommandInterpreter(connection: RecordingConnection(), baseDirectory: NSTemporaryDirectory())
        interpreter.output = { [unowned self] in self.lines.append($0) }
    }

    func test_helpListsEveryVerbUnderItsGroup() {
        interpreter.handleCommand("help")

        XCTAssertEqual(lines.filter { !$0.hasPrefix("  ") }, ["Build:", "Files:", "Navigation:", "Session:"])
        let mentioned = lines.joined(separator: "\n")
        for verb in ["build", "wait", "errors", "check", "tools", "debug", "nudge", "reset",
                     "push", "rm", "cp", "export", "ls", "cd", "pwd", "base", "begin", "quit", "semel stop"] {
            XCTAssertTrue(mentioned.contains("  \(verb)"), "help does not name \(verb)")
        }
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_helpAboutOneVerbIsItsLineAlone() {
        interpreter.handleCommand("help build")

        XCTAssertEqual(lines.count, 2, lines.joined(separator: "\n"))
        XCTAssertEqual(lines[0], "Build:")
        XCTAssertTrue(lines[1].contains("build <folder> [--into <dir>] [--no-follow]"), lines[1])
    }

    func test_helpAboutAnAliasFindsTheCommand() {
        interpreter.handleCommand("help e")

        XCTAssertTrue(lines.last?.contains("errors") == true, lines.joined(separator: "\n"))
    }

    func test_helpAboutNothingKnownSaysSo() {
        XCTAssertEqual(interpreter.handleCommand("help frobnicate"), .failed)
        XCTAssertEqual(lines, ["help: no command named frobnicate"])
    }

    func test_aTypoNamesTheNearestVerb() {
        XCTAssertEqual(interpreter.handleCommand("buidl hello"), .failed)
        XCTAssertEqual(lines, ["Unknown command: buidl — did you mean build? `help` lists them all"])
    }

    func test_aWordNearNothingGetsNoGuess() {
        XCTAssertEqual(interpreter.handleCommand("frobnicate"), .failed)
        XCTAssertEqual(lines, ["Unknown command: frobnicate; `help` lists them"])
    }

    func test_theNearestVerbIsWithinAFewEdits() {
        let verbs: Set<String> = ["build", "push", "wait", "errors", "export"]
        XCTAssertEqual(CommandInterpreter.nearestVerb(to: "buidl", among: verbs), "build")
        XCTAssertEqual(CommandInterpreter.nearestVerb(to: "pussh", among: verbs), "push")
        XCTAssertEqual(CommandInterpreter.nearestVerb(to: "erors", among: verbs), "errors")
        XCTAssertNil(CommandInterpreter.nearestVerb(to: "xyzzy", among: verbs))
        XCTAssertNil(CommandInterpreter.nearestVerb(to: "w", among: verbs), "one letter is not a typo of anything")
    }
}
