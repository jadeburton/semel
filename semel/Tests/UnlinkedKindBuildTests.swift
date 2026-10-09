//
//  UnlinkedKindBuildTests.swift
//  SemelCLITests
//
//  B-130. What `build` shows when the graph holds a node of a kind this server does not
//  link and a push wakes it: every file pushed, the node named with its kind and the way
//  out, and a failed build — not `No errors.` over an empty export. A live loop, because
//  the node's error is what the pass that picks it up publishes.
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class UnlinkedKindBuildTests: XCTestCase {

    private var engine: BuildEngine!
    private var interpreter: CommandInterpreter!
    private var externalRoot: URL!

    /// A kind no type claims, as a removed type's number is to a server built without it.
    private let unlinkedKind: UInt = 999_999

    override func setUpWithError() throws {
        try super.setUpWithError()
        DataObjectStore.shared = DataObjectStore(storeRoot: makeTempDirectory())
        externalRoot = makeTempDirectory()
        try FileManager.default.createDirectory(at: externalRoot.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        engine.startProcessingLoop()
        let handler = RequestHandler(engine: engine, database: database, databasePath: "/tmp/test-graph.sqlite")
        interpreter = CommandInterpreter(connection: InProcessConnection(handler: handler),
                                         baseDirectory: externalRoot.path)
        _ = try interpreter.connect()
        engine.waitUntilIdleBlocking()
    }

    override func tearDown() {
        engine.stopProcessingLoop()
        engine = nil
        BuildEngine.shared = nil
        interpreter = nil
        super.tearDown()
    }

    private func makeTempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-cli-tests/\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ relativePath: String, _ text: String) throws {
        try text.write(to: externalRoot.appendingPathComponent(relativePath), atomically: true, encoding: .utf8)
    }

    /// A product read through a node standing where the tutorial's `MyLineCounter` stood:
    /// between a source and the product. Built once while its type is linked, then its row
    /// is given a kind nothing links — what the server finds after the type is removed.
    private func buildThenUnlinkTheMiddleNode() throws {
        try write("src/a.config", "a.one=1\n")
        try write("src/b.config", "b.one=1\n")
        try write("src/semel.fmla", """
            product 'a.txt' = ConfigFilter(prefix: 'a', input: ['config': StaticFile(path: <a.config>).output]).output
            product 'b.txt' = StaticFile(path: <b.config>).output
            """)
        interpreter.handleCommand("build src")
        XCTAssertEqual(interpreter.errorsReported, 0, "precondition: the first build is clean")

        let database = engine.database
        let filters = try database.node.select(kind: ConfigFilter.kind)
            .filter { $0.properties[ConfigFilter.prefixProperty] == "a" }
        var filter = try XCTUnwrap(filters.first)
        filter.kind = unlinkedKind
        try database.node.update(filter)
    }

    func test_aBuildThatWakesANodeOfAnUnlinkedKindPushesEveryFileAndReportsTheNode() throws {
        try buildThenUnlinkTheMiddleNode()
        try write("src/a.config", "a.one=2\n")
        try write("src/b.config", "b.one=2\n")
        let destination = makeTempDirectory()
        var lines: [String] = []
        interpreter.output = { lines.append($0) }

        interpreter.handleCommand("build src --into \(destination.path)")

        let transcript = lines.joined(separator: "\n")
        XCTAssertTrue(lines.contains("Push file: src/a.config"), transcript)
        XCTAssertTrue(lines.contains("Push file: src/b.config"), "the push goes on past the file that woke it\n\(transcript)")
        XCTAssertFalse(transcript.contains("couldn’t be completed"), transcript)
        XCTAssertFalse(transcript.contains("couldn't be completed"), transcript)
        XCTAssertFalse(lines.contains("No errors."), transcript)

        guard let block = lines.firstIndex(of: "a node of kind \(unlinkedKind) is of a type this server does not link") else {
            return XCTFail("the report names the node by its kind\n\(transcript)")
        }
        XCTAssertEqual(Array(lines[block...].prefix(3)),
                       ["a node of kind \(unlinkedKind) is of a type this server does not link",
                        "  needed by: a.txt",
                        "  register: kind \(unlinkedKind)"], transcript)
        XCTAssertGreaterThan(interpreter.errorsReported, 0)
        XCTAssertEqual(lines.last, "1 error · 1 product without a value · 1 of 2 products exported", transcript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("b.txt").path),
                      "--into gets what has a value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
    }
}
