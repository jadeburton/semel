//
//  BuildCommandTests.swift
//  SemelCLITests
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelNodeKit
import SemelProtocol
import SemelServer
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

    /// A product whose source failed: one node with something of its own to say, which is
    /// what a report counts and what a scripted build's exit status rests on.
    private func publishFailedProduct(_ name: String, message: String) throws {
        _ = try BuildEngine.shared.inputFileSystem.ensureEntirePathExistsAsFolders(Path("stand-in"), pinned: true)
        let (source, _) = try GraphSpecNode.parse("StaticFile(path: 'input:/stand-in/\(name)')").findOrCreateMatchingNode()
        let (product, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/src/\(name)')").findOrCreateMatchingNode()
        try Wire.connectWire(database: BuildEngine.shared.database,
                             fromNodeID: try source.requireID(),
                             fromSymbolID: StaticFile.outputPort.asSymbolID(),
                             toNodeID: try product.requireID(),
                             toSymbolID: OutputFile.inputPort.asSymbolID(),
                             name: "product".asSymbolID())
        // Written after the wiring, which puts every output of its target back to pending.
        try source.writeToOutputPort(StaticFile.outputPort,
                                     value: .noValue(reason: .error(messageDataObjectHash: try message.intern())))
    }

    /// With no loop running the wait returns at once, so the macro's three steps are
    /// observable in order: the push happened, the wait settled, the report ran.
    func test_buildPushesWaitsAndReports() throws {
        interpreter.handleCommand("build src")

        let pushed = try XCTUnwrap(try BuildEngine.shared.inputFileSystem.childNode(path: "src/main.c"))
        XCTAssertNotNil(pushed)
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_buildTakesExactlyOneFolder() throws {
        XCTAssertEqual(interpreter.handleCommand("build"), .failed)

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    /// The exit status of a scripted run rests on this count, so an error a command
    /// reports must land in it — here a push of something that is not there.
    func test_aReportedErrorIsCounted() throws {
        interpreter.handleCommand("push nowhere")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    /// A build error is what the exit status is for: the `errors` report has to count,
    /// not just print. A product whose source failed is one error, named at the source.
    func test_aBuildErrorIsCounted() throws {
        try publishFailedProduct("broken.a", message: "the source is gone")

        interpreter.handleCommand("build src")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    // MARK: - Following the formula's inputs (B-110)

    /// The graph a formula in `hello/` leaves when it names `<../clang.cfg>`: a source
    /// nobody pushed, and a node that needs it. No loop runs, so the shape is laid by hand.
    private func nameConfigBesideTheBuildFolder() throws {
        try FileManager.default.createDirectory(at: externalRoot.appendingPathComponent("hello"),
                                                withIntermediateDirectories: true)
        try "include 'clang'".write(to: externalRoot.appendingPathComponent("hello/hello.fmla"),
                                    atomically: true, encoding: .utf8)
        try "clang.compiler.target=x".write(to: externalRoot.appendingPathComponent("clang.cfg"),
                                            atomically: true, encoding: .utf8)
        let (config, _)   = try GraphSpecNode.parse("StaticFile(path: 'input:/clang.cfg')").findOrCreateMatchingNode()
        let (selector, _) = try GraphSpecNode.parse("ConfigFilter(prefix: 'clang.compiler')").findOrCreateMatchingNode()
        try Wire.connectWire(database: BuildEngine.shared.database,
                             fromNodeID: try config.requireID(),
                             fromSymbolID: StaticFile.outputPort.asSymbolID(),
                             toNodeID: try selector.requireID(),
                             toSymbolID: ConfigFilter.inputPort.asSymbolID(),
                             name: "config".asSymbolID())
    }

    private func configIsPushed() throws -> Bool {
        let node = try XCTUnwrap(try BuildEngine.shared.inputFileSystem.childNode(path: "clang.cfg"))
        return try XCTUnwrap(node.nodeAsAny() as? StaticFile).isPinned
    }

    /// The settle reports `clang.cfg` as not pushed; it is beside the build folder, under
    /// the base, so `build` pushes it and waits again.
    func test_buildPushesASourceTheFormulaNeedsFromTheTree() throws {
        try nameConfigBesideTheBuildFolder()

        interpreter.handleCommand("build hello")

        XCTAssertTrue(try configIsPushed())
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_noFollowPushesTheNamedFolderAlone() throws {
        try nameConfigBesideTheBuildFolder()

        interpreter.handleCommand("build hello --no-follow")

        XCTAssertFalse(try configIsPushed())
        XCTAssertEqual(interpreter.errorsReported, 1, "the unpushed config is the report")
    }

    /// A source the report names that is not on disk stays the error it is.
    func test_aSourceMissingFromDiskIsNotPushedAndStaysReported() throws {
        try nameConfigBesideTheBuildFolder()
        try FileManager.default.removeItem(at: externalRoot.appendingPathComponent("clang.cfg"))

        interpreter.handleCommand("build hello")

        XCTAssertFalse(try configIsPushed())
        XCTAssertEqual(interpreter.errorsReported, 1)
    }

    /// The line says where the source is from the formula's point of view, which is how
    /// the formula spelled it.
    func test_theSourceIsNamedRelativeToTheFormulasFolder() {
        XCTAssertEqual(CommandInterpreter.relativePath(to: "clang.cfg", from: "hello"), "../clang.cfg")
        XCTAssertEqual(CommandInterpreter.relativePath(to: "swift/MyLibrary", from: "swift/MyApp"), "../MyLibrary")
        XCTAssertEqual(CommandInterpreter.relativePath(to: "hello/extra.h", from: "hello"), "extra.h")
    }

    // MARK: - --into

    /// The destination is the opt-in: with one, a clean build ends with its products on
    /// disk, which is what a build step is for.
    func test_aDestinationExportsTheProductsAfterACleanBuild() throws {
        try publishProduct("lib.a", contents: "archive")
        let destination = makeTempDirectory()

        interpreter.handleCommand("build src --into \(destination.path)")

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("lib.a"), encoding: .utf8), "archive")
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_withoutADestinationNothingIsExported() throws {
        try publishProduct("lib.a", contents: "archive")

        interpreter.handleCommand("build src")

        XCTAssertEqual(interpreter.errorsReported, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.currentDirectoryPath + "/lib.a"))
    }

    /// A partial product set beside a non-zero exit would only mislead.
    func test_aBuildThatReportedErrorsExportsNothing() throws {
        try publishProduct("lib.a", contents: "archive")
        try publishFailedProduct("broken.a", message: "the source is gone")
        let destination = makeTempDirectory()

        interpreter.handleCommand("build src --into \(destination.path)")

        XCTAssertEqual(interpreter.errorsReported, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func test_intoNeedsADirectory() throws {
        interpreter.handleCommand("build src --into")

        XCTAssertEqual(interpreter.errorsReported, 1)
    }
}
