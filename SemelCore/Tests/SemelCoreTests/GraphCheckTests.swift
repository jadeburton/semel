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

        XCTAssertEqual(GraphCheck.run(database: database).findings, [])
    }

    // MARK: - Which graph the findings are about

    /// Counted from the same read as the findings, because it is what decides how to read
    /// them: a node the engine has not finished wiring looks exactly like a node whose
    /// wiring is missing, and only this number tells the two apart.
    func test_theReportCountsTheNodesThatWereStillScheduled() throws {
        let node = try makeConfiguration(role: "source")

        let scheduled = GraphCheck.run(database: database).scheduledNodeCount
        XCTAssertGreaterThan(scheduled, 0, "a node that declares inputs is scheduled when it is created")

        try database.node.updateScheduled(nodeID: try node.requireID(), scheduled: false)

        XCTAssertEqual(GraphCheck.run(database: database).scheduledNodeCount, scheduled - 1)
    }

    // MARK: - A graph the check could not read

    /// A check that could not look is not a check that found nothing. Silence here would
    /// print as `✅ no findings`, which is the one answer a damaged graph must never get.
    func test_reportsATableItCouldNotReadRatherThanAnsweringClean() throws {
        try makeHealthyGraph()
        try database.dbQueue.write { try $0.execute(sql: "DROP TABLE CacheEntry") }

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings, [GraphCheck.Finding(
            kind: .graphCouldNotBeRead, subject: "the cache table",
            sentence: "it could not be read, so whatever it had to say is missing from this report")])
    }

    /// With no nodes to compare against, every wire in the graph looks like it points at
    /// nothing. An unreadable table must not become a finding per row: the checks that rest
    /// on it are skipped, and the one line that stays says which.
    func test_anUnreadableNodeTableSkipsTheChecksThatRestOnItRatherThanFailingEveryRow() throws {
        try makeHealthyGraph()
        try database.dbQueue.write { try $0.execute(sql: "DROP TABLE Node") }

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings, [GraphCheck.Finding(
            kind: .graphCouldNotBeRead, subject: "the node table",
            sentence: "it could not be read, so wires, output ports, graph specs, products, folder manifests and "
                    + "error ports were not checked")])
    }

    /// The same the other way round: with no wires, every required input port is a product
    /// nothing produces. The product here is wired and sound, which is what makes the
    /// finding it would otherwise draw a false one.
    func test_anUnreadableWireTableSkipsTheChecksThatRestOnIt() throws {
        let source = try makeConfiguration(role: "source")
        let (product, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/app')").findOrCreateMatchingNode()
        try Wire.connectWire(database: database,
                             fromNodeID:   try source.requireID(),
                             fromSymbolID: Configuration.outputPort.asSymbolID(),
                             toNodeID:     try product.requireID(),
                             toSymbolID:   OutputFile.inputPort.asSymbolID(),
                             name:         "link".asSymbolID())
        try Folder.flushDirtyManifests()
        XCTAssertEqual(GraphCheck.run(database: database).findings, [], "the graph is sound to begin with")

        try database.dbQueue.write { try $0.execute(sql: "DROP TABLE Wire") }

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings, [GraphCheck.Finding(
            kind: .graphCouldNotBeRead, subject: "the wire table",
            sentence: "it could not be read, so wires and products were not checked")])
    }

    /// Without the marks, a folder waiting for its rebuild is a folder whose manifest
    /// disagrees with its children — the engine working as designed, reported as a defect.
    func test_anUnreadableMetadataTableSkipsTheManifestCheck() throws {
        try push("src/hello.c", contents: "int hello(void) { return 0; }")
        try database.dbQueue.write { try $0.execute(sql: "DROP TABLE Metadata") }

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings, [GraphCheck.Finding(
            kind: .graphCouldNotBeRead, subject: "the metadata table",
            sentence: "it could not be read, so folder manifests were not checked")])
    }

    /// First, whatever its kind sorts as: it is what the rest of the report has to be read
    /// against, and a reader who takes a short list for a short list of problems has been
    /// misled by the order alone.
    func test_whatCouldNotBeReadIsSaidBeforeTheFindings() throws {
        let (node, _) = try GraphSpecNode.parse("OutputFile(path: 'output:/app')").findOrCreateMatchingNode()
        try Folder.flushDirtyManifests()
        try database.dbQueue.write { try $0.execute(sql: "DROP TABLE CacheEntry") }

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.map(\.kind), [.graphCouldNotBeRead, .productWithNoProducer], "\(findings)")
        XCTAssertEqual(findings.last?.subject, "OutputFile #\(try node.requireID()) 'output:/app'")
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

        let findings = GraphCheck.run(database: database).findings

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

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .danglingWire)
        XCTAssertEqual(findings.first?.sentence, "Configuration #\(try source.requireID()) has no output port 'goneAway'")
    }

    /// The same end asked the question the other end is asked: a port dropped from a type
    /// leaves its row behind, and a wire still hanging off that row is handed whatever it
    /// last held, forever, by a port nothing will ever write again.
    func test_findsAWireFromAnOutputPortItsTypeDoesNotDeclare() throws {
        let source   = try makeConfiguration(role: "source")
        let consumer = try makeConfiguration(role: "consumer")

        try database.outputPort.insertOrUpdate(
            OutputPort(nodeID:         try source.requireID(),
                       nameSymbolID:   "goneAway".asSymbolID(),
                       valueKind:      .pending,
                       dataObjectHash: nil))
        _ = try database.wire.insert(Wire(fromNodeID:   try source.requireID(),
                                          fromSymbolID: "goneAway".asSymbolID(),
                                          toNodeID:     try consumer.requireID(),
                                          toSymbolID:   Configuration.inputPort.asSymbolID(),
                                          name:         "link".asSymbolID()))

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .danglingWire)
        XCTAssertEqual(findings.first?.sentence,
                       "Configuration #\(try source.requireID()) declares no output port 'goneAway'")
    }

    // MARK: - A port its type declares and the node holds no row for

    /// Every node is given a row per declared port when it is created, so one without is a
    /// node something damaged — and a read of that port has nothing true to answer.
    func test_findsANodeHoldingNoRowForAnOutputPortItsTypeDeclares() throws {
        let node = try makeConfiguration(role: "source")
        _ = try database.outputPort.delete(nodeID: try node.requireID(),
                                           nameSymbolID: Configuration.outputPort.asSymbolID())

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .missingOutputPort)
        XCTAssertEqual(findings.first?.subject, "Configuration #\(try node.requireID())")
        XCTAssertEqual(findings.first?.sentence,
                       "its type declares the output port 'output', and it holds no row for it")
    }

    // MARK: - A graph spec that cannot be read back, or names a type nobody links

    func test_findsAGraphSpecNamingATypeTheServerDoesNotLink() throws {
        var node = try makeConfiguration(role: "source")
        node.graphSpec = "NoSuchType(role: 'source')"
        try database.node.update(node)

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .unlinkedNodeType)
        XCTAssertEqual(findings.first?.sentence,
                       "its graph spec names the type 'NoSuchType', which this server does not link")
    }

    /// The column is nullable only because a row exists for a moment before its spec is
    /// patched in. A NULL that survives is a node the matcher can never reach again, which
    /// is the same defect as a spec that will not parse.
    func test_findsANodeWithNoGraphSpecAtAll() throws {
        var node = try makeConfiguration(role: "source")
        node.graphSpec = nil
        try database.node.update(node)

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .unreadableGraphSpec)
        XCTAssertEqual(findings.first?.sentence, "it has no graph spec, so nothing can match it again")
    }

    func test_findsAGraphSpecThatCannotBeReadBack() throws {
        var node = try makeConfiguration(role: "source")
        node.graphSpec = "Configuration(role: 'source'"
        try database.node.update(node)

        let findings = GraphCheck.run(database: database).findings

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

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .productWithNoProducer)
        XCTAssertEqual(findings.first?.subject, "OutputFile #\(try node.requireID()) 'output:/app'")
        XCTAssertEqual(findings.first?.sentence,
                       "nothing is wired to its required input port 'input', so it can never be produced")
    }

    // MARK: - A folder manifest disagreeing with the folder

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

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .missingManifestChild)
        XCTAssertEqual(findings.first?.sentence, "its manifest names the child 'ghost.c', which does not exist")
    }

    /// The other direction, which is the one a manifest left stale produces: the child is
    /// there and the manifest does not mention it, so everything downstream of the folder
    /// builds as though the file had never been pushed.
    func test_findsAChildTheManifestDoesNotName() throws {
        try push("src/hello.c", contents: "int hello(void) { return 0; }")
        try push("src/main.c", contents: "int main(void) { return hello(); }")
        try Folder.flushDirtyManifests()

        let folder = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "src"))
        let manifest = FolderManifest(baseFolderPath: "input:/src",
                                      entries: [FolderManifestEntry(name: "hello.c", isFolder: false, isPinned: true)])
        try database.outputPort.insertOrUpdate(
            OutputPort(nodeID:         try folder.requireID(),
                       nameSymbolID:   Folder.folderManifestOutputPort.asSymbolID(),
                       valueKind:      .value,
                       dataObjectHash: try manifest.toJSON().intern()))

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .missingManifestChild)
        XCTAssertEqual(findings.first?.sentence, "the child 'main.c' exists, and its manifest does not name it")
    }

    // MARK: - An error port with no message, or none that can be read

    func test_findsAnErrorPortCarryingNoMessage() throws {
        let node = try makeConfiguration(role: "source")

        try database.outputPort.insertOrUpdate(
            OutputPort(nodeID:         try node.requireID(),
                       nameSymbolID:   Configuration.outputPort.asSymbolID(),
                       valueKind:      .error,
                       dataObjectHash: nil))

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .errorWithoutMessage)
        XCTAssertEqual(findings.first?.sentence,
                       "its port 'output' is in error with no message, so nothing says what failed")
    }

    /// A message the port names and the object store cannot produce is a different and
    /// worse defect than one that was never written, so it is said differently.
    func test_findsAnErrorPortWhoseMessageCannotBeRead() throws {
        let node = try makeConfiguration(role: "source")

        try database.outputPort.insertOrUpdate(
            OutputPort(nodeID:         try node.requireID(),
                       nameSymbolID:   Configuration.outputPort.asSymbolID(),
                       valueKind:      .error,
                       dataObjectHash: String(repeating: "ab", count: 32)))

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .errorWithoutMessage)
        XCTAssertEqual(findings.first?.sentence,
                       "its port 'output' is in error and its message cannot be read back from the "
                     + "object store, so what failed is lost")
    }

    /// B-104. A removed source carries no message and is not supposed to: it is a state,
    /// and the report writes the sentence for it from the path. The finding is about a node
    /// that failed and said nothing, which this is not.
    func test_doesNotFindARemovedSourceCarryingNoMessage() throws {
        let node = try makeConfiguration(role: "source")

        try database.outputPort.insertOrUpdate(
            OutputPort(nodeID:         try node.requireID(),
                       nameSymbolID:   Configuration.outputPort.asSymbolID(),
                       valueKind:      .deleted,
                       dataObjectHash: nil))

        XCTAssertEqual(GraphCheck.run(database: database).findings.filter { $0.kind == .errorWithoutMessage },
                       [])
    }

    // MARK: - A cache entry whose key is not the shape a key has

    func test_findsACacheEntryWhoseKeyIsNotAHash() throws {
        try database.cacheEntry.save(CacheEntry(hash: "not-a-hash", content: Data([1, 2, 3]), cost: 20, timestamp: Date()))
        try database.cacheEntry.save(CacheEntry(hash: Sha256.hash(Array("well formed".utf8)),
                                                  content: Data([4, 5, 6]), cost: 20, timestamp: Date()))

        let findings = GraphCheck.run(database: database).findings

        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(findings.first?.kind, .unreadableCacheKey)
        XCTAssertEqual(findings.first?.subject, "cache entry 'not-a-hash'")
    }
}
