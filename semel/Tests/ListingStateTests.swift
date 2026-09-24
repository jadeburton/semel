//
//  ListingStateTests.swift
//  SemelCLITests
//
//  B-74. What `ls` says beside a name is what the port behind that name says, and the
//  states are not one state: a source that was pushed and then removed settles by itself
//  once the collector reaches it, a product whose input failed is a failure to act on, and
//  a name nobody has produced anything for is neither. One word for all three tells the
//  reader nothing.
//
//  Driven the whole way — a real graph behind `RequestHandler.list` over
//  `InProcessConnection`, and the client's own renderer on the other end — so what is
//  asserted is the line a person reads.
//

@testable import SemelCLI
@testable import SemelCore
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import SemelServer
import XCTest

final class ListingStateTests: XCTestCase {

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
        // The product is one of the pushed files, so the shape is a real build's — a
        // builder, a product under `output:`, the product downstream of the source — with
        // no toolchain in it.
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

    // MARK: - Driving the client

    /// One `ls`, rendered by the client's own renderer against the real server.
    private func lines(_ fileSystem: FileSystemForCommand, _ pathOrWildcard: String) throws -> [String] {
        let context = TestCommandContext(connection: connection, baseDirectory: externalRoot.path)
        context.currentFileSystem = fileSystem
        try NavigationPlugin().handle(verb: "ls", tokens: [pathOrWildcard], context: context)
        return context.messages
    }

    /// A product whose input carries a message of its own, wired the way a builder wires
    /// one: the source stands in for whatever failed to produce the bytes.
    private func wireFailedProduct(_ name: String) throws {
        let (source, _)  = try GraphSpecNode.parse("StaticFile(path: 'input:/stand-in/\(name)')")
            .findOrCreateMatchingNode()
        let (product, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/made/\(name)')")
            .findOrCreateMatchingNode()
        try Wire.connectWire(database: engine.database,
                             fromNodeID: try source.requireID(),
                             fromSymbolID: StaticFile.outputPort.asSymbolID(),
                             toNodeID: try product.requireID(),
                             toSymbolID: OutputFile.inputPort.asSymbolID(),
                             name: "product".asSymbolID())
        // Written after the wiring, which puts every output of its target back to pending.
        try source.writeToOutputPort(StaticFile.outputPort,
                                     value: .noValue(reason: .error(messageDataObjectHash: try "the tool failed".intern())))
        engine.waitUntilIdleBlocking()
    }

    /// A product nothing has produced: the source the formula names was never pushed, so
    /// its port holds the state of a value nobody has made and the product reads that.
    private func wireUnproducedProduct(_ name: String) throws {
        let (source, _)  = try GraphSpecNode.parse("StaticFile(path: 'input:/stand-in/\(name)')")
            .findOrCreateMatchingNode()
        let (product, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/made/\(name)')")
            .findOrCreateMatchingNode()
        try Wire.connectWire(database: engine.database,
                             fromNodeID: try source.requireID(),
                             fromSymbolID: StaticFile.outputPort.asSymbolID(),
                             toNodeID: try product.requireID(),
                             toSymbolID: OutputFile.inputPort.asSymbolID(),
                             name: "product".asSymbolID())
        engine.waitUntilIdleBlocking()
    }

    // MARK: - The states

    /// A pushed source and the product built from it are both there. Nothing to say.
    func test_aPushedSourceAndItsBuiltProductCarryNoNote() throws {
        interpreter.handleCommand("build src")

        XCTAssertEqual(try lines(.input, "src"), [
            "-rw-r--r--        28  main.c",
            "-rw-r--r--        47  semel.fmla",
        ])
        XCTAssertEqual(try lines(.output, "src"), [
            "-rw-r--r--        28  main.txt",
        ])
    }

    /// A source the user removed while something still names it stands until the collector
    /// reaches it. The word says it is going, not that it failed.
    func test_aRemovedSourceIsListedAsDeleted() throws {
        interpreter.handleCommand("build src")

        interpreter.handleCommand("rm src/main.c")
        interpreter.handleCommand("wait")

        XCTAssertEqual(try lines(.input, "src"), [
            "-rw-r--r--         -  main.c  [deleted]",
            "-rw-r--r--        47  semel.fmla",
        ])
    }

    /// A product whose input is in error is a failure to act on, and says so.
    func test_aProductWhoseInputFailedIsListedAsFailed() throws {
        try wireFailedProduct("broken.a")

        XCTAssertEqual(try lines(.output, "made"), [
            "-rw-r--r--         -  broken.a  [failed]",
        ])
    }

    /// A product whose input has never had a value is neither failing nor going away.
    func test_aProductWhoseInputWasNeverProducedIsListedAsNotProduced() throws {
        try wireUnproducedProduct("unpushed.a")

        XCTAssertEqual(try lines(.output, "made"), [
            "-rw-r--r--         -  unpushed.a  [not produced]",
        ])
        XCTAssertEqual(try lines(.input, "stand-in"), [
            "-rw-r--r--         -  unpushed.a  [not produced]",
        ])
    }
}
