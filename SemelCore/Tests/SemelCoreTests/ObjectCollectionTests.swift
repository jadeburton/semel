//
//  ObjectCollectionTests.swift
//  SemelCore
//
//  B-14. The store's collector: what counts as a reference — a port, a cached build, an
//  artifact snapshot, an archived graph, and the two document kinds that name other
//  objects — and the age below which nothing is collected whatever refers to it.
//

@testable import SemelCore
import Foundation
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class ObjectCollectionTests: SemelCoreTestCase {

    private var database: DatabaseLayer!
    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        database = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private var store: DataObjectStore { DataObjectStore.shared }

    /// An object no row refers to, interned an hour ago as far as the collector can tell.
    private func agedOrphan(_ text: String) throws -> DataObjectHash {
        let hash = try [UInt8](text.utf8).intern()
        try age(hash)
        return hash
    }

    private func age(_ hash: DataObjectHash) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)],
                                              ofItemAtPath: store.objectURL(hash: hash).path)
    }

    /// A source file's port carrying `hash`: the plainest reference there is.
    private func port(holding hash: DataObjectHash, at path: String = "input:/a.c") throws {
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(path)')").findOrCreateMatchingNode()
        try node.writeToOutputPort(StaticFile.outputPort, value: .value(hash))
    }

    // MARK: - What is collected

    func test_anObjectNothingRefersToIsRemovedAndAReferencedOneKept() throws {
        let orphan = try agedOrphan("nobody refers to this object, and it is old enough to go")
        let referenced = try agedOrphan("a port refers to this one, however old it is")
        try port(holding: referenced)

        let collection = try engine.collectUnreferencedObjects()

        XCTAssertEqual(collection.removed, 1)
        XCTAssertGreaterThan(collection.removedBytes, 0)
        XCTAssertFalse(store.exists(hash: orphan))
        XCTAssertTrue(store.exists(hash: referenced))
    }

    /// An object is interned before the row that refers to it is written, so one younger
    /// than the margin is left alone — referenced or not.
    func test_aYoungObjectIsKeptWhateverRefersToIt() throws {
        let young = try [UInt8]("interned a moment ago, about to be referred to".utf8).intern()

        let collection = try engine.collectUnreferencedObjects()

        XCTAssertEqual(collection.removed, 0)
        XCTAssertTrue(store.exists(hash: young))
        XCTAssertEqual(try engine.collectUnreferencedObjects(olderThan: -1).removed, 1, "with no margin it goes")
    }

    // MARK: - What counts as a reference

    func test_anErrorMessageAPortCarriesIsKept() throws {
        let message = try agedOrphan("the tool failed, and this is what it said")
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: 'input:/b.c')").findOrCreateMatchingNode()
        try node.writeToOutputPort(StaticFile.outputPort, value: .noValue(reason: .error(documentHash: message)))

        _ = try engine.collectUnreferencedObjects()

        XCTAssertTrue(store.exists(hash: message))
    }

    func test_theFilesATreeManifestNamesAreKept() throws {
        let file = try agedOrphan("a file inside a tree, named only by the tree's manifest")
        let manifest = try TreeManifest(entries: [TreeManifestEntry(path: "lib/a.o", hash: file, mode: 0o644)]).toJSON().intern()
        try age(manifest)
        try port(holding: manifest)

        let collection = try engine.collectUnreferencedObjects()

        XCTAssertEqual(collection.removed, 0)
        XCTAssertTrue(store.exists(hash: file))
    }

    /// A content-root document names files and subfolders' documents, which name theirs:
    /// the walk follows the chain to the end.
    func test_theChildrenAContentRootDocumentNamesAreKeptThroughSubfolders() throws {
        let file = try agedOrphan("a file two folders down, named by the inner document")
        let inner = try FolderContentRoot.document(of: [(name: "deep.c", kind: .file, content: .file(hash: file, mode: 0o644))]).intern()
        let outer = try FolderContentRoot.document(of: [(name: "sub", kind: .folder, content: .hash(inner)),
                                                        (name: "gone.c", kind: .file, content: .deleted)]).intern()
        try age(inner)
        try age(outer)
        try port(holding: outer)

        let collection = try engine.collectUnreferencedObjects()

        XCTAssertEqual(collection.removed, 0)
        XCTAssertTrue(store.exists(hash: inner))
        XCTAssertTrue(store.exists(hash: file))
    }

    func test_aCachedBuildsOutputsAreKept() throws {
        let output = try agedOrphan("an output no node holds any more, but a cache entry does")
        let message = try agedOrphan("and an error message a cached failure carries")
        let entry = ProcessCacheEntry(outputValues: ["output": .value(output),
                                                     "errorLog": .noValue(reason: .error(documentHash: message))],
                                      specTable: GraphSpecTable(inputWireSpecs: [:], rows: [:]),
                                      keyMaterial: CacheKeyMaterial(nodeType: "SampleTool", implementationVersion: 1,
                                                                    properties: [], fingerprint: nil, inputs: []))
        try database.cacheEntry.save(CacheEntry(hash: String(repeating: "c", count: 64),
                                                content: try JSONEncoder().encode(entry), cost: 1, timestamp: Date()))

        let collection = try engine.collectUnreferencedObjects()

        XCTAssertEqual(collection.removed, 0)
        XCTAssertTrue(store.exists(hash: output))
        XCTAssertTrue(store.exists(hash: message))
    }

    func test_anArtifactSnapshotsObjectIsKept() throws {
        let artifact = try agedOrphan("what a product held at the last settle, per its snapshot")
        try database.artifactSnapshot.upsert(path: "output:/app", contentHash: artifact)

        _ = try engine.collectUnreferencedObjects()

        XCTAssertTrue(store.exists(hash: artifact))
    }

    /// A graph `reset` copied aside still refers to its objects, and stays readable
    /// because they are kept — even once the live graph has let them go.
    func test_anArchivedGraphsObjectsAreKept() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-collect-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        database = try DatabaseLayer(filePath: folder.appendingPathComponent("graph.sqlite").path)
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
        let remembered = try agedOrphan("held by a port of the graph that was copied aside")
        try port(holding: remembered)
        let archive = try XCTUnwrap(database.pathForCopyAside(suffix: ".broken-20260927T000000Z"))
        try database.copyAside(to: archive)
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: 'input:/a.c')").findOrCreateMatchingNode()
        _ = try database.outputPort.deleteAll(nodeID: try node.requireID())

        let collection = try engine.collectUnreferencedObjects()

        XCTAssertEqual(collection.removed, 0, "the archive refers to it")
        XCTAssertTrue(store.exists(hash: remembered))
        try FileManager.default.removeItem(at: folder)
    }

    // MARK: - Reading the documents

    func test_theCollectorReadsOnlyTheTwoDocumentKindsAndLeavesFilesAlone() throws {
        let file = try agedOrphan("{\"kind\":27,\"object\":\"not a manifest, just text that starts like one\"}")
        let plain = try agedOrphan("hash abcdef, in a file that is no document at all")

        XCTAssertEqual(BuildEngine.objects(namedByDocument: file, in: store), [])
        XCTAssertEqual(BuildEngine.objects(namedByDocument: plain, in: store), [])
        XCTAssertEqual(BuildEngine.objects(inContentRootDocument: FolderContentRoot.formatTag
                                           + "\nfile\thash 0a0b mode 644\t3\ta.c\nfolder\thash 0c0d\t3\tsub\nfolder\tnot-produced\t1\ts\n"),
                       ["0a0b", "0c0d"])
    }
}
