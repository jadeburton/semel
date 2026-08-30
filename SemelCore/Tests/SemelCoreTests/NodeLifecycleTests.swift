//
//  NodeLifecycleTests.swift
//  build_system_tests
//
//  Creation, pinning and the deferred delete cascade for the file-system node types.
//  Three of the defects found in review lived in this path: a resurrected pending
//  deletion, a stale folder manifest, and a bulk delete that skipped the notification.
//

@testable import SemelCore
import XCTest
import SemelNodeKit

final class NodeLifecycleTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try DatabaseLayer()
        engine = try BuildEngine(database: database, startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDown() {
        engine = nil
        super.tearDown()
    }

    private var database: DatabaseLayer { engine.database }

    // MARK: - Manifest pinned state

    /// The manifest reads pinned state straight from the output ports in one query per
    /// kind, rather than asking each child through `Pinnable`. That is faster but loses
    /// the polymorphism, so this asserts the two readings still agree — across a pinned
    /// file, a ghost (referenced but removed), a pinned subfolder and an empty one.
    func test_manifestPinnedStateAgreesWithEachChildsOwn() throws {
        try pushFile("mixed/kept.swift")
        try pushFile("mixed/ghost.swift")
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("mixed/sub"), pinned: true)
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(Path("mixed/unpinnedsub"), pinned: false)

        let ghost = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "mixed/ghost.swift"))
        _ = try XCTUnwrap(ghost.nodeAsAny() as? StaticFile).replaceContent(nil)

        let folder = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "mixed"))
        let manifestJSON = try folder.readFromOutputPort(Folder.folderManifestOutputPort)
            .expectValue().resolveAsString()
        let manifest = try XCTUnwrap(try PolyFactory.decode(encodedJSON: manifestJSON) as? FolderManifest)

        XCTAssertFalse(manifest.entries.isEmpty)
        for entry in manifest.entries {
            let child = try XCTUnwrap(try folder.childNode(path: entry.name))
            let expected = try (child.nodeAsAny() as? Pinnable)?.isPinned ?? false
            XCTAssertEqual(entry.isPinned, expected,
                           "\(entry.name): manifest says \(entry.isPinned), the node says \(expected)")
        }
    }

    // MARK: - Name collisions

    /// Two children of one folder sharing a name makes the tree ambiguous: `childNode`
    /// walks by name and takes the first match, so which node a path reaches depends on
    /// database ordering. `ensureEntirePathExistsAsFolders` already refused to walk such
    /// a folder — this stops the state being created in the first place.
    func test_aFileCannotTakeTheNameOfAnExistingSiblingFolder() throws {
        _ = try engine.outputFileSystem.ensureEntirePathExistsAsFolders(Path("build_system"), pinned: false)

        XCTAssertThrowsError(try GraphShapeNode.parse("OutputFile(path: 'output:/build_system')")
                                .findOrCreateMatchingNode()) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("build_system"), "should name the collision, got \(message)")
        }
    }

    func test_aFolderCannotTakeTheNameOfAnExistingSiblingFile() throws {
        _ = try GraphShapeNode.parse("OutputFile(path: 'output:/product')").findOrCreateMatchingNode()

        XCTAssertThrowsError(try engine.outputFileSystem.ensureEntirePathExistsAsFolders(
            Path("product/nested"), pinned: false))
    }

    /// A rejected creation must not leave the half-built row behind — createNode inserts
    /// before it knows the node's name, so the check happens after the insert.
    func test_aRejectedNameCollisionLeavesNoOrphanNode() throws {
        _ = try engine.outputFileSystem.ensureEntirePathExistsAsFolders(Path("collide"), pinned: false)
        let before = try database.node.selectAll().count

        _ = try? GraphShapeNode.parse("OutputFile(path: 'output:/collide')").findOrCreateMatchingNode()

        XCTAssertEqual(try database.node.selectAll().count, before)
    }

    /// Nameless nodes (compilers, linkers — everything that is not a file-system entry)
    /// share a nil name by design and must not be caught by the check.
    func test_namelessNodesAreNotTreatedAsColliding() throws {
        let first  = try GraphShapeNode.parse("Configuration(moduleName: 'A')").findOrCreateMatchingNode()
        let second = try GraphShapeNode.parse("Configuration(moduleName: 'B')").findOrCreateMatchingNode()

        XCTAssertNotEqual(try first.0.requireID(), try second.0.requireID())
    }

    // MARK: - Helpers

    /// Creates a StaticFile in the input file system, with content unless told otherwise.
    @discardableResult
    private func pushFile(_ relativePath: String, contents: String? = "int main(){}") throws -> StaticFile {
        let fullPath = Path(Folder.inputFileSystemName) / Path(relativePath)
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(
                Path(relativePath).deletingLastComponent ?? .empty, pinned: true)

        let shape = try GraphShapeNode.parse("StaticFile(path: '\(fullPath.string)')")
        let (node, _) = try shape.findOrCreateMatchingNode()
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)

        if let contents {
            _ = try file.replaceContent(try contents.intern())
        }
        return file
    }

    private func makeConfiguration(role: String) throws -> NodeRecord {
        let shape = try GraphShapeNode.parse("Configuration(role: '\(role)').output")
        let (node, _) = try shape.findOrCreateMatchingNode()
        return node
    }

    private func connect(from source: NodeRecord, to consumer: NodeRecord, name: String) throws {
        try Wire.connectWire(database: database,
                             fromNodeID: try source.requireID(),
                             fromSymbolID: "output".asSymbolID(),
                             toNodeID: try consumer.requireID(),
                             toSymbolID: "inherit".asSymbolID(),
                             name: name.asSymbolID())
    }

    private func runGarbageCollection() throws {
        while try engine.processPendingDeletions() > 0 { }
    }

    private func stillExists(_ nodeID: ObjectID) -> Bool {
        (try? database.node.select(nodeID: nodeID)) != nil
    }

    private func isPendingDeletion(_ nodeID: ObjectID) throws -> Bool {
        try XCTUnwrap(database.node.select(nodeID: nodeID)).pendingDeletion
    }

    // MARK: - Pinning

    // "Pinned" for a StaticFile means the user actually pushed content. It is what stops
    // a file the user cares about being garbage-collected.
    func test_aPushedFileIsPinnedAndNotDeletable() throws {
        let file = try pushFile("src/hello.c")

        XCTAssertTrue(try file.isPinned)
        XCTAssertFalse(try file.canBeDeleted())
    }

    func test_aFileWithNoContentIsNotPinned() throws {
        let file = try pushFile("src/empty.c", contents: nil)

        XCTAssertFalse(try file.isPinned)
        XCTAssertTrue(try file.canBeDeleted())
    }

    func test_replaceContentReportsWhetherAnythingChanged() throws {
        let file = try pushFile("src/hello.c", contents: nil)

        XCTAssertTrue(try file.replaceContent(try "first".intern()))
        XCTAssertFalse(try file.replaceContent(try "first".intern()),
                       "rewriting identical content is not a change")
        XCTAssertTrue(try file.replaceContent(try "second".intern()))
    }

    // MARK: - rm and the deferred collection

    func test_removingAnUnreferencedFileMarksItAndTheCollectorTakesIt() throws {
        let file = try pushFile("src/hello.c")
        let nodeID = try file.requireID()

        try file.deleteInInputFileSystem()
        XCTAssertTrue(try isPendingDeletion(nodeID), "rm defers to the idle-time collector")

        try runGarbageCollection()
        XCTAssertFalse(stillExists(nodeID), "an unreferenced deleted file should be collected")
    }

    /// A file that is still wired to a consumer stays in the graph as a `[missing]` ghost:
    /// the build still refers to it, so removing the node would break the graph.
    func test_removingAReferencedFileLeavesAGhostRatherThanCollectingIt() throws {
        let file = try pushFile("src/hello.c")
        let nodeID = try file.requireID()
        let consumer = try makeConfiguration(role: "consumer")
        try connect(from: try database.node.select(nodeID: nodeID), to: consumer, name: "src")

        try file.deleteInInputFileSystem()
        try runGarbageCollection()

        XCTAssertTrue(stillExists(nodeID), "a referenced file must survive as a ghost")
        XCTAssertFalse(try XCTUnwrap(database.node.select(nodeID: nodeID).nodeAsAny() as? StaticFile).isPinned,
                       "but it is no longer pinned — its content is gone")
    }

    /// The collector's own rescue guard: a node that still has a consumer when the pass
    /// reaches it is un-marked rather than collected.
    ///
    /// The mark is set *after* wiring on purpose. `connectWire` clears the flag itself, so
    /// marking first would leave nothing for the collector to rescue and this would pass
    /// no matter what the collector did.
    func test_theCollectorUnmarksANodeThatStillHasAConsumer() throws {
        let file = try pushFile("src/hello.c", contents: nil)
        let nodeID = try file.requireID()

        let consumer = try makeConfiguration(role: "consumer")
        try connect(from: try database.node.select(nodeID: nodeID), to: consumer, name: "src")
        try database.node.updatePendingDeletion(nodeID: nodeID, pendingDeletion: true)

        try runGarbageCollection()

        XCTAssertTrue(stillExists(nodeID), "a node with a consumer must not be collected")
        XCTAssertFalse(try isPendingDeletion(nodeID),
                       "the collector should clear a mark it has decided not to act on")
    }

    func test_aMarkedFileThatIsStillPinnedIsNotCollected() throws {
        let file = try pushFile("src/hello.c")
        let nodeID = try file.requireID()
        try database.node.updatePendingDeletion(nodeID: nodeID, pendingDeletion: true)

        try runGarbageCollection()

        XCTAssertTrue(stillExists(nodeID), "content the user pushed is not garbage")
        XCTAssertFalse(try isPendingDeletion(nodeID))
    }

    // MARK: - Cascade

    // Collecting a node deletes its input wires, which can leave its upstream with no
    // consumers — that upstream is then collected on a later pass.
    func test_collectionCascadesUpstream() throws {
        let upstream = try makeConfiguration(role: "upstream")
        let middle = try makeConfiguration(role: "middle")
        try connect(from: upstream, to: middle, name: "link")

        let upstreamID = try upstream.requireID()
        let middleID = try middle.requireID()

        try database.node.updatePendingDeletion(nodeID: middleID, pendingDeletion: true)
        try runGarbageCollection()

        XCTAssertFalse(stillExists(middleID))
        XCTAssertFalse(stillExists(upstreamID),
                       "the upstream lost its last consumer and should follow")
    }

    // MARK: - Folder

    func test_aFolderWithAPinnedChildCannotBeDeleted() throws {
        try pushFile("src/hello.c")
        let folder = try XCTUnwrap(engine.inputFileSystem.childNode(path: Path("src")))
        let folderFunction = try XCTUnwrap(folder.nodeAsAny() as? Folder)

        XCTAssertFalse(try folderFunction.canBeDeleted(),
                       "a folder holding content the user pushed is not garbage")
    }

    func test_aFoldersManifestListsItsChildren() throws {
        try pushFile("src/hello.c")
        let folder = try XCTUnwrap(engine.inputFileSystem.childNode(path: Path("src")))

        let manifest = try folder.readFromOutputPort(Folder.folderManifestOutputPort)
            .expectValue().resolveAsString()

        XCTAssertTrue(manifest.contains("hello.c"), "got \(manifest)")
    }

    /// The stale-manifest defect: a folder that loses a child has to rebuild its manifest,
    /// or downstream nodes keep reading a listing of files that are gone.
    func test_aFoldersManifestIsRefreshedWhenAChildGoesAway() throws {
        let file = try pushFile("src/hello.c")
        let folder = try XCTUnwrap(engine.inputFileSystem.childNode(path: Path("src")))

        let before = try folder.readFromOutputPort(Folder.folderManifestOutputPort)
            .expectValue().resolveAsString()
        XCTAssertTrue(before.contains("hello.c"), "precondition: the child is listed")

        try file.deleteInInputFileSystem()
        try runGarbageCollection()

        let after = try XCTUnwrap(engine.inputFileSystem.childNode(path: Path("src")))
            .readFromOutputPort(Folder.folderManifestOutputPort)
            .expectValue().resolveAsString()
        XCTAssertFalse(after.contains("hello.c"),
                       "the manifest must stop advertising a deleted child, got \(after)")
    }

    func test_deletingAFolderInTheInputFileSystemClearsItsChildren() throws {
        try pushFile("src/a.c")
        try pushFile("src/b.c")
        let folder = try XCTUnwrap(engine.inputFileSystem.childNode(path: Path("src")))
        let folderFunction = try XCTUnwrap(folder.nodeAsAny() as? Folder)

        try folderFunction.deleteInInputFileSystem()
        try runGarbageCollection()

        XCTAssertNil(try engine.inputFileSystem.childNode(path: Path("src/a.c")))
        XCTAssertNil(try engine.inputFileSystem.childNode(path: Path("src/b.c")))
    }
}
