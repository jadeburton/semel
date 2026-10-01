//
//  ProgramDrivenCommandTests.swift
//  SemelCLITests
//
//  B-126. What the interpreter offers a program that drives it as a person drives the
//  prompt — `semel-watch`: commands given as their words, several paths in one push or one
//  removal, and the questions it asks the graph without printing anything.
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class ProgramDrivenCommandTests: XCTestCase {

    private var connection: InProcessConnection?
    private var interpreter: CommandInterpreter?
    private var externalRoot: URL?
    private var store: URL?
    private var lines: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        let store = makeTempDirectory()
        self.store = store
        DataObjectStore.shared = DataObjectStore(storeRoot: store)
        let externalRoot = makeTempDirectory()
        self.externalRoot = externalRoot
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let database = try DatabaseLayer()
        let engine   = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        let handler  = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        let connection = InProcessConnection(handler: handler)
        self.connection = connection
        let interpreter = CommandInterpreter(connection: connection, baseDirectory: externalRoot.path)
        interpreter.output = { [weak self] in self?.lines.append($0) }
        self.interpreter = interpreter
    }

    override func tearDownWithError() throws {
        BuildEngine.shared = nil
        connection  = nil
        interpreter = nil
        for directory in [externalRoot, store].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ text: String, at path: String) throws {
        let file = try XCTUnwrap(externalRoot).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Commands as words

    /// A path holding a space is one argument when the command is given as its words: no
    /// tokenizer reads it, so nothing has to be quoted.
    func test_aCommandGivenAsItsWordsTakesAPathWithASpaceAsOneArgument() throws {
        let interpreter = try XCTUnwrap(self.interpreter)
        try write("int a;", at: "My Sources/a.c")

        let result = interpreter.handleCommand(verb: "push", arguments: ["My Sources/a.c"])

        XCTAssertEqual(result, .success, lines.joined(separator: "\n"))
        XCTAssertTrue(try interpreter.inputHolds("My Sources/a.c"))
    }

    // MARK: - Several paths

    /// Several paths are one push: each pushed once and reported, and a path that matches
    /// nothing reported without stopping the rest.
    func test_severalPathsAreOnePush() throws {
        let interpreter = try XCTUnwrap(self.interpreter)
        try write("int a;", at: "src/a.c")
        try write("int b;", at: "lib/b.c")

        let result = interpreter.handleCommand(verb: "push", arguments: ["src/a.c", "missing.c", "lib/b.c", "src/a.c"])

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(lines, ["push: missing.c: no such file or directory", "Push file: src/a.c", "Push file: lib/b.c"])
        XCTAssertTrue(try interpreter.inputHolds("src/a.c"))
        XCTAssertTrue(try interpreter.inputHolds("lib/b.c"))
    }

    /// Several paths are one removal, reported together.
    func test_severalPathsAreOneRemoval() throws {
        let interpreter = try XCTUnwrap(self.interpreter)
        try write("int a;", at: "src/a.c")
        try write("int b;", at: "src/b.c")
        try write("int c;", at: "lib/c.c")
        interpreter.handleCommand(verb: "push", arguments: ["src", "lib"])
        lines = []

        let result = interpreter.handleCommand(verb: "rm", arguments: ["src/a.c", "lib"])

        XCTAssertEqual(result, .success, lines.joined(separator: "\n"))
        XCTAssertEqual(lines, ["Removed folder: lib", "Removed file: src/a.c"])
        XCTAssertFalse(try interpreter.inputHolds("src/a.c"))
        XCTAssertTrue(try interpreter.inputHolds("src/b.c"))
    }

    // MARK: - Questions without output

    /// Held is what was pushed and not removed; a path below a folder the graph does not
    /// have is not held either, rather than an error.
    func test_inputHoldsWhatWasPushedAndNotWhatWasRemoved() throws {
        let interpreter = try XCTUnwrap(self.interpreter)
        try write("int a;", at: "src/a.c")
        try write("int b;", at: "src/b.c")
        interpreter.handleCommand(verb: "push", arguments: ["src"])
        interpreter.handleCommand(verb: "rm", arguments: ["src/b.c"])
        lines = []

        XCTAssertTrue(try interpreter.inputHolds("src"))
        XCTAssertTrue(try interpreter.inputHolds("src/a.c"))
        XCTAssertFalse(try interpreter.inputHolds("src/b.c"))
        XCTAssertFalse(try interpreter.inputHolds("nowhere/c.c"))
        XCTAssertEqual(lines, [], "a question prints nothing")
        XCTAssertEqual(interpreter.errorsReported, 0)
    }

    func test_aGraphWithNothingFailingHasNoErrors() throws {
        let interpreter = try XCTUnwrap(self.interpreter)
        try write("int a;", at: "src/a.c")
        interpreter.handleCommand(verb: "push", arguments: ["src"])

        XCTAssertFalse(try interpreter.graphHasErrors())
    }

    /// A path kept out of pushes is left out of a push of the folder above it, as `build`'s
    /// export folder is.
    func test_aPathKeptOutOfPushesIsLeftOutOfAPushOfItsFolder() throws {
        let interpreter = try XCTUnwrap(self.interpreter)
        try write("int a;", at: "src/a.c")
        try write("product", at: "src/out/a")

        interpreter.excludeFromPush("src/out")
        interpreter.handleCommand(verb: "push", arguments: ["src"])

        XCTAssertTrue(try interpreter.inputHolds("src/a.c"))
        XCTAssertFalse(try interpreter.inputHolds("src/out/a"))
    }

    /// A client that leaves the reports to another is not subscribed, so the engine sends
    /// it no events to print.
    func test_aClientThatDoesNotSubscribeIsSentNoEvents() throws {
        let interpreter = try XCTUnwrap(self.interpreter)
        let connection  = try XCTUnwrap(self.connection)

        _ = try interpreter.connect(subscribing: false)

        XCTAssertFalse(connection.session.isSubscribed)
    }

    // MARK: - Exporting the root

    /// `export .` is every product: the root of the output file system, which a listing
    /// cannot name, is always there.
    func test_exportOfTheRootExportsEveryProduct() throws {
        let interpreter = try XCTUnwrap(self.interpreter)
        _ = try BuildEngine.shared.inputFileSystem.ensureEntirePathExistsAsFolders(Path("stand-in"), pinned: true)
        let (source, _) = try GraphSpecNode.staticFile(at: "input:/stand-in/hello").findOrCreateMatchingNode()
        _ = try XCTUnwrap(source.nodeAsAny() as? StaticFile).replaceContent(try "hello".intern())
        _ = try GraphSpecNode(OutputFile.self, properties: [OutputFile.pathProperty: "output:/app/hello"],
                              inputs: [OutputFile.inputPort: ["product": .staticFile(at: "input:/stand-in/hello")]])
            .findOrCreateMatchingNode()
        let destination = try XCTUnwrap(externalRoot).appendingPathComponent("exported")

        let result = interpreter.handleCommand(verb: "export", arguments: [".", "--into", destination.path])

        XCTAssertEqual(result, .success, lines.joined(separator: "\n"))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("app/hello"), encoding: .utf8), "hello")
    }
}
