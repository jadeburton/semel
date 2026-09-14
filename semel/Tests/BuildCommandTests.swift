//
//  BuildCommandTests.swift
//  SemelCLITests
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelNodeKit
import SemelProtocol
import SemelServ
import XCTest

/// B-57. `build <folder>` is the loop in one word — push, wait, errors — and a scripted
/// run exits non-zero when any command reported an error, which is what makes it a build
/// step rather than an interactive convenience.
final class BuildCommandTests: XCTestCase {

    private var connection: InProcessConnection!
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
        let engine   = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        let handler  = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        connection   = InProcessConnection(handler: handler)
        interpreter  = CommandInterpreter(connection: connection, baseDirectory: externalRoot.path)
    }

    override func tearDown() {
        BuildEngine.shared = nil
        connection = nil
        interpreter = nil
        super.tearDown()
    }

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true)
    }

    /// A product under `output:/src`, wired to a static file standing in for its builder.
    private func publishProduct(_ name: String, contents: String) throws {
        // Pinned, as a push would leave it; an unpinned folder is one the graph reports.
        _ = try BuildEngine.shared.inputFileSystem.ensureEntirePathExistsAsFolders(Path("stand-in"), pinned: true)
        let (source, _) = try GraphSpecNode.parse("StaticFile(path: 'input:/stand-in/\(name)')").findOrCreateMatchingNode()
        _ = try XCTUnwrap(source.nodeAsAny() as? StaticFile).replaceContent(try contents.intern())
        let (product, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/src/\(name)')").findOrCreateMatchingNode()
        try Wire.connectWire(database: BuildEngine.shared.database,
                             fromNodeID: try source.requireID(),
                             fromSymbolID: StaticFile.outputPort.asSymbolID(),
                             toNodeID: try product.requireID(),
                             toSymbolID: OutputFile.inputPort.asSymbolID(),
                             name: "product".asSymbolID())
    }

    /// With no loop running the wait returns at once, so the macro's three steps are
    /// observable in order: the push happened, the wait settled, the report ran.
    func test_buildPushesWaitsAndReports() throws {
        try interpreter.handleCommand("build src")

        let pushed = try XCTUnwrap(try BuildEngine.shared.inputFileSystem.childNode(path: "src/main.c"))
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

    /// A build error is what the exit status is for: the `errors` report has to count,
    /// not just print. An output file nothing feeds carries an error from creation.
    func test_aBuildErrorIsCounted() throws {
        _ = try GraphSpecNode.parse("OutputFile(path: 'output:/src/unfed.a')").findOrCreateMatchingNode()

        try interpreter.handleCommand("build src")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    // MARK: - --into

    /// The destination is the opt-in: with one, a clean build ends with its products on
    /// disk, which is what a build step is for.
    func test_aDestinationExportsTheProductsAfterACleanBuild() throws {
        try publishProduct("lib.a", contents: "archive")
        let destination = makeTempDirectory()

        try interpreter.handleCommand("build src --into \(destination.path)")

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("lib.a"), encoding: .utf8), "archive")
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_withoutADestinationNothingIsExported() throws {
        try publishProduct("lib.a", contents: "archive")

        try interpreter.handleCommand("build src")

        XCTAssertEqual(interpreter.errorsReported, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/lib.a"))
    }

    /// A partial product set beside a non-zero exit would only mislead.
    func test_aBuildThatReportedErrorsExportsNothing() throws {
        try publishProduct("lib.a", contents: "archive")
        _ = try GraphSpecNode.parse("OutputFile(path: 'output:/src/unfed.a')").findOrCreateMatchingNode()
        let destination = makeTempDirectory()

        try interpreter.handleCommand("build src --into \(destination.path)")

        XCTAssertEqual(interpreter.errorsReported, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func test_intoNeedsADirectory() throws {
        try interpreter.handleCommand("build src --into")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }
}
