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

    private func connect(_ from: NodeRecord, _ fromPort: String,
                         to: NodeRecord, _ toPort: String, named name: String) throws {
        try Wire.connectWire(database: engine.database,
                             fromNodeID: try from.requireID(),
                             fromSymbolID: fromPort.asSymbolID(),
                             toNodeID: try to.requireID(),
                             toSymbolID: toPort.asSymbolID(),
                             name: name.asSymbolID())
    }

    /// A product under `output:/made` reading one source, and the source it reads. Left as a
    /// source nobody has pushed, which is the state a formula naming a file leaves behind.
    @discardableResult
    private func wireProduct(_ name: String) throws -> NodeRecord {
        let (source, _)  = try GraphSpecNode.parse("StaticFile(path: 'input:/stand-in/\(name)')")
            .findOrCreateMatchingNode()
        let (product, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/made/\(name)')")
            .findOrCreateMatchingNode()
        try connect(source, StaticFile.outputPort, to: product, OutputFile.inputPort, named: "product")
        engine.waitUntilIdleBlocking()
        return source
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
    /// reaches it. The word says it is going, not that it failed — and the product that
    /// cannot be made without it says the other thing, because what the user removed is a
    /// source and not an artifact. Here the product is wired straight to the source, so its
    /// input carries the removal itself.
    func test_aRemovedSourceIsListedAsDeletedAndItsProductAsFailed() throws {
        interpreter.handleCommand("build src")

        interpreter.handleCommand("rm src/main.c")
        interpreter.handleCommand("wait")

        XCTAssertEqual(try lines(.input, "src"), [
            "-rw-r--r--         -  main.c  [deleted]",
            "-rw-r--r--        47  semel.fmla",
        ])
        XCTAssertEqual(try lines(.output, "src"), [
            "-rw-r--r--         -  main.txt  [failed]",
        ])
    }

    /// The shape every real build has: something stands between the source and the product.
    /// A node that demands its input is stopped by a removed source the way a compiler is,
    /// and publishes a failure of its own — so the product reads the same word it reads when
    /// it is wired straight to the source. One user action, one word, whatever the distance.
    func test_aProductBehindABuilderWhoseSourceWasRemovedIsListedAsFailed() throws {
        interpreter.handleCommand("push src")
        let (source, _) = try GraphSpecNode.parse("StaticFile(path: 'input:/src/main.c')")
            .findOrCreateMatchingNode()
        let (builder, _) = try GraphSpecNode.parse("TreeBuilder()").findOrCreateMatchingNode()
        let (product, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/made/bundle.tree')")
            .findOrCreateMatchingNode()
        try connect(source, StaticFile.outputPort, to: builder, TreeBuilder.inputPort, named: "main.c")
        try connect(builder, TreeBuilder.outputPort, to: product, OutputFile.inputPort, named: "product")
        engine.waitUntilIdleBlocking()

        interpreter.handleCommand("rm src/main.c")
        interpreter.handleCommand("wait")

        XCTAssertEqual(try lines(.output, "made"), [
            "-rw-r--r--         -  bundle.tree  [failed]",
        ])
    }

    /// A product whose input is in error is a failure to act on, and says so.
    func test_aProductWhoseInputFailedIsListedAsFailed() throws {
        let source = try wireProduct("broken.a")
        // Written after the wiring, which puts every output of its target back to pending.
        try source.writeToOutputPort(StaticFile.outputPort,
                                     value: .noValue(reason: .error(messageDataObjectHash: try "the tool failed".intern())))
        engine.waitUntilIdleBlocking()

        XCTAssertEqual(try lines(.output, "made"), [
            "-rw-r--r--         -  broken.a  [failed]",
        ])
    }

    /// A product whose input has never had a value is neither failing nor going away; the
    /// source behind it is one nobody pushed, which is what `input:` calls it (B-118).
    func test_aProductWhoseInputWasNeverProducedIsListedAsNotProduced() throws {
        try wireProduct("unpushed.a")

        XCTAssertEqual(try lines(.output, "made"), [
            "-rw-r--r--         -  unpushed.a  [not produced]",
        ])
        XCTAssertEqual(try lines(.input, "stand-in"), [
            "-rw-r--r--         -  unpushed.a  [not pushed]",
        ])
    }
}
