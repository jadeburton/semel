//
//  FolderManifestRebuildTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// B-25. A folder's manifest used to be rebuilt on every child change — twice per pushed
/// file, each rebuild O(children) — so pushing N files into one folder was quadratic.
/// These pin the cost in rebuilds, which a counter can assert, and the growth in time,
/// which only a ratio can.
final class FolderManifestRebuildTests: SemelCoreTestCase {

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

    /// The same sequence `FilePlugin.handlePush` runs per file.
    private func push(_ relativePath: String, contents: String) throws {
        _ = try engine.inputFileSystem.ensureEntirePathExistsAsFolders(
                Path(relativePath).deletingLastComponent ?? .empty, pinned: true)
        let fullPath = Path(Folder.inputFileSystemName) / Path(relativePath)
        let (node, _) = try GraphSpecNode.parse("StaticFile(path: '\(fullPath.string)')").findOrCreateMatchingNode()
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
        _ = try file.replaceContent(try contents.intern())
    }

    @discardableResult
    private func pushFiles(_ count: Int, into folder: String) throws -> TimeInterval {
        let start = Date.now
        for index in 0..<count {
            try push("\(folder)/file\(index).c", contents: "int f\(index)(void) { return \(index); }")
        }
        return Date.now.timeIntervalSince(start)
    }

    private func manifest(of folderPath: String) throws -> FolderManifest {
        let folder = try XCTUnwrap(try engine.inputFileSystem.childNode(path: folderPath))
        let json = try folder.readFromOutputPort(Folder.folderManifestOutputPort).expectValue().resolveAsString()
        return try XCTUnwrap(try TypeRegistry.decode(encodedJSON: json) as? FolderManifest)
    }

    private func dirtyKeys() throws -> [String] {
        try engine.database.metadata.selectKeys(withPrefix: Folder.manifestDirtyKeyPrefix)
    }

    // MARK: - Waking the loop

    /// The rebuild that used to happen on every push wrote the manifest port, which
    /// scheduled consumers and so woke the loop. Deferring it to the next pass means the
    /// push itself has to ask for that pass — the first real build after B-25 pushed 203
    /// files into a sleeping engine and nothing was ever scheduled.
    func test_aPushAsksTheEngineForAPass() throws {
        _ = try engine.inputFileSystem
        let before = engine.wakeUpsRequested

        try push("src/main.c", contents: "int main(void) { return 0; }")

        XCTAssertGreaterThan(engine.wakeUpsRequested, before, "a push must wake the processing loop")
        XCTAssertFalse(try dirtyKeys().isEmpty, "and leave the manifest for that pass to rebuild")
    }

    // MARK: - Cost

    /// Pushing N files into one folder rebuilds its manifest once — when it is next read —
    /// not twice per file. The folder's own creation builds one manifest (`didCreate`),
    /// which is the only other rebuild in the count.
    func test_pushingManyFilesRebuildsTheManifestOnceNotTwicePerFile() throws {
        _ = try engine.inputFileSystem   // the root's own creation builds its first manifest
        let before = Folder.manifestRebuildCount

        try pushFiles(50, into: "many")
        let duringPushes = Folder.manifestRebuildCount - before
        XCTAssertEqual(duringPushes, 1, "only the folder's creation should build a manifest while pushing")

        let entries = try manifest(of: "many").entries
        XCTAssertEqual(entries.count, 50)
        XCTAssertEqual(Folder.manifestRebuildCount - before, 2, "the read rebuilds exactly once")

        _ = try manifest(of: "many")
        XCTAssertEqual(Folder.manifestRebuildCount - before, 2, "a second read of a clean manifest rebuilds nothing")
    }

    /// The growth has to be linear now. 800 files against 200 is four times the work; the
    /// old quadratic cost made it about sixteen. The bound is loose because it is a timing.
    func test_pushCostGrowsLinearlyWithTheFolderSize() throws {
        let small = try pushFiles(200, into: "small")
        let large = try pushFiles(800, into: "large")

        XCTAssertLessThan(large / small, 10, "200 files: \(small)s, 800 files: \(large)s")
    }

    // MARK: - Freshness: every reader sees the current children

    func test_aManifestReadRightAfterAPushIsCurrent() throws {
        try push("fresh/a.c", contents: "a")
        XCTAssertEqual(try manifest(of: "fresh").entries.map(\.name), ["a.c"])

        try push("fresh/b.c", contents: "b")
        XCTAssertEqual(try manifest(of: "fresh").entries.map(\.name).sorted(), ["a.c", "b.c"])
    }

    func test_aContentChangeAndAPinChangeAreVisibleOnTheNextRead() throws {
        try push("state/f.c", contents: "1")
        _ = try manifest(of: "state")

        let node = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "state/f.c"))
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
        _ = try file.replaceContent(nil as DataObjectHash?)   // a ghost: referenced but removed

        let entry = try XCTUnwrap(try manifest(of: "state").entries.first { $0.name == "f.c" })
        XCTAssertFalse(entry.isPinned, "the ghost state must be visible immediately")
    }

    func test_aDeletionIsVisibleOnTheNextRead() throws {
        try push("gone/keep.c", contents: "k")
        try push("gone/drop.c", contents: "d")
        _ = try manifest(of: "gone")

        let node = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "gone/drop.c"))
        let file = try XCTUnwrap(node.nodeAsAny() as? StaticFile)
        try file.deleteInInputFileSystem()

        // A user delete is deferred: the file becomes a ghost at once and is collected at
        // idle. Both states have to be visible on the next read.
        let ghost = try XCTUnwrap(try manifest(of: "gone").entries.first { $0.name == "drop.c" })
        XCTAssertFalse(ghost.isPinned, "deleted by the user, so no longer pinned")

        _ = try engine.processPendingDeletions()

        XCTAssertFalse(try manifest(of: "gone").entries.contains { $0.name == "drop.c" },
                       "collected, so gone from the manifest")
    }

    /// Wildcard matching enumerates the database, not the manifest, so it is current by
    /// construction; pinned here so that stays true.
    func test_wildcardMatchingSeesAPushImmediately() throws {
        try push("glob/x.c", contents: "x")

        let matcher = FileWildcardMatcher(input: InternalFileSystemLister(folder: try engine.inputFileSystem))
        let matches = try matcher.findAllMatching(pathOrWildcard: Path("glob/*.c"))

        XCTAssertEqual(matches.count, 1, "got \(matches)")
    }

    // MARK: - The processing pass

    /// The pass flushes before it selects, and the rebuild's port write is what schedules
    /// the manifest's consumers — ProjectFinder watches the input root.
    func test_theProcessingPassFlushesDirtyManifestsAndSchedulesConsumers() throws {
        // ProjectFinder wires itself to the root manifest when it first processes.
        try engine.projectFinder.makeNode().processWithPreCheck()
        _ = try manifest(of: "")            // the root, clean
        try engine.projectFinder.setScheduled(false)

        try push("pkg/main.swift", contents: "print(1)")
        XCTAssertFalse(try dirtyKeys().isEmpty, "a push marks the parent dirty")
        XCTAssertFalse(try engine.database.node.select(nodeID: try engine.projectFinder.requireID()).scheduled,
                       "nothing is scheduled until the manifest is rebuilt")

        let flushed = try Folder.flushDirtyManifests()

        XCTAssertGreaterThanOrEqual(flushed, 1)
        XCTAssertTrue(try dirtyKeys().isEmpty)
        XCTAssertTrue(try engine.database.node.select(nodeID: try engine.projectFinder.requireID()).scheduled,
                      "the root manifest changed, so its consumer is scheduled")
    }

    /// The mark lives in the database, so a crash between a push and the next pass leaves
    /// something the next launch can act on rather than a manifest nothing rebuilds.
    func test_theDirtyMarkIsPersistedAndClearedByTheFlush() throws {
        try push("durable/f.c", contents: "f")
        let folder = try XCTUnwrap(try engine.inputFileSystem.childNode(path: "durable"))

        XCTAssertNotNil(try engine.database.metadata.select(key: "\(Folder.manifestDirtyKeyPrefix)\(try folder.requireID())"))

        try Folder.flushDirtyManifests()

        XCTAssertNil(try engine.database.metadata.select(key: "\(Folder.manifestDirtyKeyPrefix)\(try folder.requireID())"))
        XCTAssertEqual(try manifest(of: "durable").entries.map(\.name), ["f.c"])
    }

    /// A mark whose folder has since been collected is dropped, not an error.
    func test_aMarkForACollectedFolderIsDroppedByTheFlush() throws {
        try engine.database.metadata.upsert(key: "\(Folder.manifestDirtyKeyPrefix)999999", value: "1")

        XCTAssertNoThrow(try Folder.flushDirtyManifests())
        XCTAssertTrue(try dirtyKeys().isEmpty)
    }

    // MARK: - Measurement

    /// Not an assertion, a measurement: prints the wall-clock and rebuild count for three
    /// sizes so the growth can be read off. Run by hand with `--filter`.
    func test_measurePushCost() throws {
        for count in [200, 1000, 3000] {
            let before = Folder.manifestRebuildCount
            let seconds = try pushFiles(count, into: "bench\(count)")
            let rebuilds = Folder.manifestRebuildCount - before
            print("B-25 measure: \(count) files in \(String(format: "%.3f", seconds))s, \(rebuilds) manifest rebuilds")
        }
    }
}
