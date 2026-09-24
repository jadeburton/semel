//
//  GraphCheckTests.swift
//  SemelCoreTests
//
//  One broken invariant per test, planted in the database directly.
//
//  The faults here cannot be reached through the engine's own API: that is the point of
//  the check. A wire to a node that does not exist is what `connectWire` refuses to make
//  and what a defect made anyway; a graph spec naming a type nobody links is what a server
//  built without a package reads back. So each test writes the row, and asserts that the
//  check finds that one thing and nothing else.
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class GraphCheckTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var database: DatabaseLayer { engine.database }

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    // MARK: - A graph nothing is wrong with

    /// Two wired configurations, a folder holding two pushed files, and the file-system
    /// roots the engine builds under them. Everything the checks look at is present and
    /// agrees with everything else.
    @discardableResult
    private func makeHealthyGraph() throws -> NodeRecord {
        let source   = try makeConfiguration(role: "source")
        let consumer = try makeConfiguration(role: "consumer")
        try Wire.connectWire(database: database,
                             fromNodeID:   try source.requireID(),
                             fromSymbolID: Configuration.outputPort.asSymbolID(),
                             toNodeID:     try consumer.requireID(),
                             toSymbolID:   Configuration.inputPort.asSymbolID(),
                             name:         "link".asSymbolID())

        try push("src/hello.c", contents: "int hello(void) { return 0; }")
        try push("src/main.c", contents: "int main(void) { return hello(); }")

        // The manifests are rebuilt on demand, and a folder waiting for its rebuild is
        // passed over — so flush, or the check the folders are here for never runs.
        try Folder.flushDirtyManifests()

        return consumer
    }

    private func makeConfiguration(role: String) throws -> NodeRecord {
        let (node, _) = try GraphSpecNode.parse("Configuration(role: '\(role)')").findOrCreateMatchingNode()
        return node
    }

    /// The sequence a push runs, which is how a file and its folders enter the graph.
    @discardableResult
    private func push(_ relativePath: String, contents: String) throws -> NodeRecord {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(
                Path(relativePath).deletingLastComponent ?? .empty, pinned: true)
        let fullPath = Path(Folder.inputFileSystemName) / Path(relativePath)
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(fullPath.string)')").findOrCreateMatchingNode()
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
        _ = try file.replaceContent(try contents.intern())
        return node
    }

    func test_aHealthyGraphYieldsNoFindings() throws {
        try makeHealthyGraph()

        XCTAssertEqual(GraphCheck.run(database: database), [])
    }

    // MARK: - A wire whose endpoint node is gone

    func test_findsAWireIntoANodeThatDoesNotExist() throws {
        let source = try makeConfiguration(role: "source")
        let missingNodeID: ObjectID = 987_654

        _ = try database.wire.insert(Wire(fromNodeID:   try source.requireID(),
                                          fromSymbolID: Configuration.outputPort.asSymbolID(),
                                          toNodeID:     missingNodeID,
                                          toSymbolID:   Configuration.inputPort.asSymbolID(),
                                          name:         "link".asSymbolID()))

        let findings = GraphCheck.run(database: database)

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .danglingWire)
        XCTAssertEqual(findings.first?.sentence, "the node it goes to, #987654, does not exist")
    }

    /// The port, not only the node: a wire from an output port that is not there is a
    /// consumer that will never be handed anything, and the node at the far end is real.
    func test_findsAWireFromAnOutputPortThatDoesNotExist() throws {
        let source   = try makeConfiguration(role: "source")
        let consumer = try makeConfiguration(role: "consumer")

        _ = try database.wire.insert(Wire(fromNodeID:   try source.requireID(),
                                          fromSymbolID: "goneAway".asSymbolID(),
                                          toNodeID:     try consumer.requireID(),
                                          toSymbolID:   Configuration.inputPort.asSymbolID(),
                                          name:         "link".asSymbolID()))

        let findings = GraphCheck.run(database: database)

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .danglingWire)
        XCTAssertEqual(findings.first?.sentence, "Configuration #\(try source.requireID()) has no output port 'goneAway'")
    }

    // MARK: - A graph spec that cannot be read back, or names a type nobody links

    func test_findsAGraphSpecNamingATypeTheServerDoesNotLink() throws {
        var node = try makeConfiguration(role: "source")
        node.graphSpec = "NoSuchType(role: 'source')"
        try database.node.update(node)

        let findings = GraphCheck.run(database: database)

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .unlinkedNodeType)
        XCTAssertEqual(findings.first?.sentence,
                       "its graph spec names the type 'NoSuchType', which this server does not link")
    }

    func test_findsAGraphSpecThatCannotBeReadBack() throws {
        var node = try makeConfiguration(role: "source")
        node.graphSpec = "Configuration(role: 'source'"
        try database.node.update(node)

        let findings = GraphCheck.run(database: database)

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .unreadableGraphSpec)
        XCTAssertTrue(findings.first?.sentence.hasPrefix("its graph spec cannot be read back — ") == true,
                      "\(findings)")
    }

    // MARK: - A product with no producer

    /// The one the prompt cannot report: the port holds `initializing`, which is a state
    /// and not a failure, so the product waits forever and nothing anywhere says so.
    func test_findsAProductWhoseRequiredInputHasNoWire() throws {
        let (node, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/app')").findOrCreateMatchingNode()
        try Folder.flushDirtyManifests()

        let findings = GraphCheck.run(database: database)

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .productWithNoProducer)
        XCTAssertEqual(findings.first?.subject, "OutputFile #\(try node.requireID()) 'output:/app'")
        XCTAssertEqual(findings.first?.sentence,
                       "nothing is wired to its required input port 'input', so it can never be produced")
    }

    // MARK: - A folder manifest naming a child that does not exist

    func test_findsAManifestNamingAChildThatIsNotThere() throws {
        try push("src/hello.c", contents: "int hello(void) { return 0; }")
        try Folder.flushDirtyManifests()

        let folder = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "src"))
        let manifest = FolderManifest(baseFolderPath: "input:/src",
                                      entries: [FolderManifestEntry(name: "hello.c", isFolder: false, isPinned: true),
                                                FolderManifestEntry(name: "ghost.c", isFolder: false, isPinned: true)])
        try database.outputPort.insertOrUpdate(
            OutputPort(nodeID:         try folder.requireID(),
                       nameSymbolID:   Folder.folderManifestOutputPort.asSymbolID(),
                       valueKind:      .value,
                       dataObjectHash: try manifest.toJSON().intern()))

        let findings = GraphCheck.run(database: database)

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .missingManifestChild)
        XCTAssertEqual(findings.first?.sentence, "its manifest names the child 'ghost.c', which does not exist")
    }

    // MARK: - An error port with no message

    func test_findsAnErrorPortCarryingNoMessage() throws {
        let node = try makeConfiguration(role: "source")

        try database.outputPort.insertOrUpdate(
            OutputPort(nodeID:         try node.requireID(),
                       nameSymbolID:   Configuration.outputPort.asSymbolID(),
                       valueKind:      .error,
                       dataObjectHash: nil))

        let findings = GraphCheck.run(database: database)

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .errorWithoutMessage)
        XCTAssertEqual(findings.first?.sentence,
                       "its port 'output' is in error with no message, so nothing says what failed")
    }

    // MARK: - A cache entry whose key is not the shape a key has

    func test_findsACacheEntryWhoseKeyIsNotAHash() throws {
        try database.cacheEntry.insert(CacheEntry(hash: "not-a-hash", content: [1, 2, 3], cost: 20, timestamp: Date()))
        try database.cacheEntry.insert(CacheEntry(hash: Sha256.hash(Array("well formed".utf8)),
                                                  content: [4, 5, 6], cost: 20, timestamp: Date()))

        let findings = GraphCheck.run(database: database)

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .unreadableCacheKey)
        XCTAssertEqual(findings.first?.subject, "cache entry 'not-a-hash'")
    }
}
