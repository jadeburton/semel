//
//  LockBarrierTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-146. A lock is a write barrier enforced at `commit`: a batch that changes a locked
/// folder lands only with the lock the folder then matches, or with the lock taken away;
/// otherwise it is replayed whole and the rejection names the folder, the lock, both roots
/// and the paths that moved it.
final class LockBarrierTests: SemelCoreTestCase {

    private var engine: BuildEngine!
    private var disk: URL!

    private let package  = "Dependencies/Pkg"
    private let lockPath = "Dependencies/Pkg.semel-lock"

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
        disk = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("semel-lock-barrier-tests/\(UUID().uuidString)", isDirectory: true)
        try write("Sources/Pkg/Pkg.swift", "public struct Pkg {}\n")
        try write("Package.swift", "// swift-tools-version: 5.9\n")
        try pushPackage(journal: nil)
        try pushLock(try lockText(), journal: nil)
        try Folder.flushDirtyManifests()
    }

    override func tearDownWithError() throws {
        engine = nil
        try? FileManager.default.removeItem(at: disk)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func write(_ relativePath: String, _ content: String) throws {
        let url = disk.appendingPathComponent(package).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The lock `prepare` would write for the package on disk now.
    private func lockText() throws -> String {
        let root = try FolderContentRoot.root(ofFolderAt: disk.appendingPathComponent(package))
        return DependencyLock(contentRoot: root, fold: FolderContentRoot.formatTag, version: "1.0.0").text
    }

    /// The package as a push of it sends it, recorded in `journal` first when there is one.
    private func pushPackage(journal: BatchJournal?) throws {
        for entry in FolderOnDisk.read(Path(package), under: disk.path).entriesToPush where entry.kind == .file {
            try push(entry.path.string,
                     try String(contentsOf: disk.appendingPathComponent(entry.path.string), encoding: .utf8),
                     journal: journal)
        }
    }

    private func push(_ path: String, _ text: String, journal: BatchJournal?) throws {
        try journal?.recordPathAndFoldersAbove(Path(path))
        _ = try StaticFile.push([UInt8](text.utf8), mode: 0o644, at: Path(path))
    }

    private func pushLock(_ text: String, journal: BatchJournal?) throws {
        try push(lockPath, text, journal: journal)
    }

    private func remove(_ path: String, journal: BatchJournal) throws {
        try journal.recordSubtree(at: Path(path))
        let node = try XCTUnwrap(try Folder.inputFileSystem.childNode(path: Path(path)))
        try XCTUnwrap(try node.nodeAsAny() as? UserDeletable).deleteInInputFileSystem()
    }

    private func inputRoot() throws -> DataObjectHash {
        try Folder.flushDirtyManifests()
        return try Checkpoints.currentInputRoot()
    }

    private func recordedRoot() throws -> DataObjectHash {
        try DependencyLock.parse(try lockText()).contentRoot
    }

    // MARK: - Rejected

    func test_aPushBelowALockedFolderWithoutItsLockIsRejectedAndLeavesInputAsItWas() throws {
        let before   = try inputRoot()
        let expected = try recordedRoot()

        let journal = try BatchJournal(identifier: "test")
        try push("\(package)/Sources/Pkg/Pkg.swift", "public struct Pkg { let edited = true }\n", journal: journal)
        try push("Sources/App/main.swift", "print(1)\n", journal: journal)

        let rejection = try XCTUnwrap(try LockBarrier.commit(journal))
        XCTAssertEqual(rejection.folder, Path(package))
        XCTAssertEqual(rejection.lock, Path(lockPath))
        XCTAssertEqual(rejection.expected, .contentRoot(expected))
        XCTAssertNotNil(rejection.found)
        XCTAssertNotEqual(rejection.found, expected)
        XCTAssertEqual(rejection.paths, [Path("\(package)/Sources/Pkg/Pkg.swift")],
                       "the paths are the batch's below the folder that moved it, and no other")
        XCTAssertEqual(try inputRoot(), before, "the whole batch is taken back, the free path with it")
        XCTAssertTrue(try journal.records().isEmpty)
    }

    func test_aBatchWithAMismatchingLockIsRejectedNamingBothRoots() throws {
        let before = try inputRoot()
        let journal = try BatchJournal(identifier: "test")
        try write("Sources/Pkg/Pkg.swift", "public struct Pkg { let version = 2 }\n")
        try pushPackage(journal: journal)
        let wrongRoot = String(repeating: "0", count: 64)
        try pushLock(DependencyLock(contentRoot: wrongRoot, fold: FolderContentRoot.formatTag).text, journal: journal)

        let rejection = try XCTUnwrap(try LockBarrier.commit(journal))
        XCTAssertEqual(rejection.expected, .contentRoot(wrongRoot))
        XCTAssertEqual(rejection.found, try FolderContentRoot.root(ofFolderAt: disk.appendingPathComponent(package)))
        XCTAssertEqual(rejection.paths, [Path(lockPath), Path("\(package)/Sources/Pkg/Pkg.swift")])
        XCTAssertEqual(try inputRoot(), before)
    }

    func test_aLockThatDoesNotParseRejectsTheBatchNamingTheLine() throws {
        let before = try inputRoot()
        let journal = try BatchJournal(identifier: "test")
        try pushLock("# a lock\nbogus 1\n", journal: journal)

        let rejection = try XCTUnwrap(try LockBarrier.commit(journal))
        XCTAssertEqual(rejection.expected, .unreadable(.unknownKey("bogus", line: 2)))
        XCTAssertEqual(rejection.paths, [Path(lockPath)])
        XCTAssertEqual(try inputRoot(), before)
    }

    func test_aLockFoldedUnderAnotherFormatRejectsTheBatch() throws {
        let journal = try BatchJournal(identifier: "test")
        try pushLock(DependencyLock(contentRoot: try recordedRoot(), fold: "semel-folder-content-root 1").text,
                     journal: journal)

        let rejection = try XCTUnwrap(try LockBarrier.commit(journal))
        XCTAssertEqual(rejection.expected, .otherFold(fold: "semel-folder-content-root 1", contentRoot: try recordedRoot()))
    }

    func test_removingTheFolderWithoutItsLockIsRejected() throws {
        let before = try inputRoot()
        let journal = try BatchJournal(identifier: "test")
        try remove(package, journal: journal)

        let rejection = try XCTUnwrap(try LockBarrier.commit(journal))
        XCTAssertEqual(rejection.folder, Path(package))
        XCTAssertTrue(rejection.paths.contains(Path("\(package)/Package.swift")), "\(rejection.paths)")
        XCTAssertEqual(try inputRoot(), before)
    }

    // MARK: - Accepted

    func test_aReVendorThatBringsItsLockLands() throws {
        let journal = try BatchJournal(identifier: "test")
        try write("Sources/Pkg/Pkg.swift", "public struct Pkg { let version = 2 }\n")
        try pushPackage(journal: journal)
        try pushLock(try lockText(), journal: journal)

        XCTAssertNil(try LockBarrier.commit(journal))
        let file = try XCTUnwrap(try Folder.inputFileSystem.childNode(path: Path("\(package)/Sources/Pkg/Pkg.swift")))
        let value = try XCTUnwrap(try XCTUnwrap(try file.nodeAsAny() as? StaticFile).read())
        XCTAssertEqual(try value.expectValue().resolveAsString(), "public struct Pkg { let version = 2 }\n")
        XCTAssertTrue(try journal.records().isEmpty)
    }

    func test_removingTheLockInTheBatchFreesTheFolder() throws {
        let journal = try BatchJournal(identifier: "test")
        try push("\(package)/Sources/Pkg/Pkg.swift", "public struct Pkg { let patched = true }\n", journal: journal)
        try remove(lockPath, journal: journal)

        XCTAssertNil(try LockBarrier.commit(journal))
    }

    func test_aBatchTouchingNoLockedFolderIsUnaffectedAndFoldsNothing() throws {
        let journal = try BatchJournal(identifier: "test")
        try push("Sources/App/main.swift", "print(1)\n", journal: journal)
        let foldsBefore = Folder.contentRootRebuildCount.value

        XCTAssertNil(try LockBarrier.commit(journal))
        XCTAssertEqual(Folder.contentRootRebuildCount.value, foldsBefore, "no locked folder, no fold at commit")
    }

    func test_aBatchThatPushesTheLockedFolderUnchangedLands() throws {
        let journal = try BatchJournal(identifier: "test")
        try pushPackage(journal: journal)
        try pushLock(try lockText(), journal: journal)

        XCTAssertNil(try LockBarrier.commit(journal))
    }

    func test_aFolderWhoseLockArrivesInTheBatchIsCheckedAgainstIt() throws {
        let journal = try BatchJournal(identifier: "test")
        try push("Dependencies/Other/File.swift", "other\n", journal: journal)
        try push("Dependencies/Other.semel-lock",
                 DependencyLock(contentRoot: String(repeating: "1", count: 64), fold: FolderContentRoot.formatTag).text,
                 journal: journal)

        let rejection = try XCTUnwrap(try LockBarrier.commit(journal))
        XCTAssertEqual(rejection.folder, Path("Dependencies/Other"))
        XCTAssertNil(try Folder.inputFileSystem.childNode(path: Path("Dependencies/Other")),
                     "the folder the batch made is taken away with it")
    }
}
