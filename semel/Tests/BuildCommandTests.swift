//
//  BuildCommandTests.swift
//  SemelCLITests
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelNodeKit
import XCTest

/// B-57. `build <folder>` is the loop in one word — push, wait, errors — and a scripted
/// run exits non-zero when any command reported an error, which is what makes it a build
/// step rather than an interactive convenience.
final class BuildCommandTests: XCTestCase {

    private var interpreter: CommandInterpreter!
    private var externalRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()
        try FileManager.default.createDirectory(at: externalRoot.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        try "int main(void) { return 0; }".write(to: externalRoot.appendingPathComponent("src/main.c"),
                                                 atomically: true, encoding: .utf8)
        let database = try DatabaseLayer()
        BuildEngine.shared = try BuildEngine(database: database, startProcessingLoop: false)
        interpreter = CommandInterpreter(database: database, buildEngine: BuildEngine.shared,
                                         baseDirectory: externalRoot.path)
    }

    override func tearDown() {
        BuildEngine.shared = nil
        interpreter = nil
        super.tearDown()
    }

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true)
    }

    /// With no loop running the wait returns at once, so the macro's three steps are
    /// observable in order: the push happened, the wait settled, the report ran.
    func test_buildPushesWaitsAndReports() throws {
        try interpreter.handleCommand("build src")

        let pushed = try XCTUnwrap(try interpreter.inputFileSystem.childNode(path: "src/main.c"))
        XCTAssertNotNil(pushed)
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_buildTakesExactlyOneFolder() throws {
        try interpreter.handleCommand("build")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    /// The exit status of a scripted run rests on this count, so an error a command
    /// reports must land in it — here a push of something that is not there.
    func test_aReportedErrorIsCounted() throws {
        try interpreter.handleCommand("push nowhere")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }
}
