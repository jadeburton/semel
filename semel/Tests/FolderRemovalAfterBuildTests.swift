//
//  FolderRemovalAfterBuildTests.swift
//  SemelCLITests
//
//  B-74's second test: nothing in the suites exercised `rm` of a whole build folder
//  through the CLI, which is where removing a prepared project found four defects at once.
//  This drives the verbs a person drives — push, rm, wait, ls, errors — over
//  `InProcessConnection`, with a live processing loop, so the collector and the idle-time
//  error report both run as they do in a session.
//
//  No tool runs: the fixture's formula names one of the pushed files as its product, so a
//  CLI test needs no toolchain and a failure here is a failure of the removal rather than
//  of clang. What a removal meets is the graph's shape, and the shape is the one every
//  build leaves — a source tree under `input:`, a builder reading its formula, and a
//  product under `output:` downstream of both.
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class FolderRemovalAfterBuildTests: XCTestCase {

    private var engine: BuildEngine!
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
        try "#define ANSWER 42".write(to: externalRoot.appendingPathComponent("src/common.h"),
                                      atomically: true, encoding: .utf8)
        // A product that is one of the pushed files, so a build needs no toolchain and the
        // shape a removal meets is still the real one: a builder, a product under `output:`,
        // and both of them downstream of the folder about to go.
        try #"product "main.txt" = StaticFile(path: <main.c>)"#
            .write(to: externalRoot.appendingPathComponent("src/semel.fmla"),
                   atomically: true, encoding: .utf8)

        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: true)
        BuildEngine.shared = engine
        let handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        connection  = InProcessConnection(handler: handler)
        interpreter = CommandInterpreter(connection: connection, baseDirectory: externalRoot.path)
        _ = try interpreter.connect()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine = nil
        BuildEngine.shared = nil
        connection = nil
        interpreter = nil
        super.tearDown()
    }

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Driving the connection

    private func listing(_ fileSystem: FileSystemKind, _ pattern: String = "*") throws -> [ListEntry] {
        let (response, _) = try connection.send(.daemon(.list(fileSystem: fileSystem, pattern: pattern)), body: nil)
        guard case .daemon(.list(let entries)) = response else {
            XCTFail("expected a listing, got \(response)")
            return []
        }
        return entries
    }

    private func errorRecords() throws -> [ErrorRecord] {
        let (response, _) = try connection.send(.daemon(.errors), body: nil)
        guard case .daemon(.errors(let records)) = response else {
            XCTFail("expected errors, got \(response)")
            return []
        }
        return records
    }

    /// Builds the folder: its formula names a product, so the push creates a
    /// `ProjectBuilder`, the builder creates the product, and `output:/src` fills the way it
    /// does after any build.
    private func build() {
        interpreter.handleCommand("build src")
    }

    // MARK: - The removal

    func test_removingTheBuildFolderLeavesNothingUnderItInEitherFileSystem() throws {
        build()
        XCTAssertEqual(try listing(.input).map(\.path), ["src"], "the push is what is being removed")
        XCTAssertEqual(try listing(.output).map(\.path), ["src"], "the product is under the same name")
        XCTAssertEqual(try listing(.output, "src/*").map(\.path), ["src/main.txt"],
                       "the build produced the product the formula names")

        interpreter.handleCommand("rm src")
        interpreter.handleCommand("wait")

        XCTAssertEqual(try listing(.input).map(\.path), [])
        XCTAssertEqual(try listing(.output).map(\.path), [])
        XCTAssertNil(try engine.inputFileSystem.childNode(path: "src"),
                     "the folder node goes with its files, not just its listing")
    }

    /// A note beside a name is a state the graph is in about it, and between the removal and
    /// the collector reaching it a folder is in one. Once the graph has settled there is
    /// nothing left to say any of them about: not `[deleted]`, not `[failed]`, not
    /// `[not produced]` — the names are gone, not standing there with a word beside them.
    func test_nothingIsLeftListedWithANoteBesideIt() throws {
        build()

        interpreter.handleCommand("rm src")
        interpreter.handleCommand("wait")

        let listed = try listing(.input) + listing(.output)
        XCTAssertTrue(listed.allSatisfy { $0.status == .none }, "listed: \(listed)")
    }

    /// The wall of errors B-74 was opened by. A removal collects what it breaks, so once the
    /// graph has settled there is no failure left to report — not one per node that read the
    /// folder, and not one at all.
    func test_theIdleErrorReportIsEmptyAfterTheRemoval() throws {
        build()

        interpreter.handleCommand("rm src")
        interpreter.handleCommand("wait")

        XCTAssertEqual(try errorRecords(), [])
        XCTAssertEqual(interpreter.errorsReported, 0, "a removal is not a build failure")
    }
}
