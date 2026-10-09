//
//  BatchJournalTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelDatabaseModels
import SemelNodeKit
import XCTest

/// B-146. A batch's journal records what each path held before the batch first changed it,
/// and a replay puts every one back: `input:` folds to the root it had before the batch, its
/// files, links, modes, folders and absences included.
final class BatchJournalTests: SemelCoreTestCase {

    private var engine: BuildEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        engine = try BuildEngine(database: try DatabaseLayer(), startProcessingLoop: false)
        BuildEngine.shared = engine
    }

    override func tearDownWithError() throws {
        engine = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func push(_ path: String, _ text: String, mode: UInt16 = 0o644, link: String? = nil,
                      journal: BatchJournal? = nil) throws {
        try journal?.recordPathAndFoldersAbove(Path(path))
        _ = try StaticFile.push([UInt8](text.utf8), mode: mode, symbolicLinkTarget: link, at: Path(path))
    }

    private func remove(_ path: String, journal: BatchJournal) throws {
        try journal.recordSubtree(at: Path(path))
        let node = try XCTUnwrap(try Folder.inputFileSystem.childNode(path: Path(path)))
        let deletable = try XCTUnwrap(try node.nodeAsAny() as? UserDeletable)
        try deletable.deleteInInputFileSystem()
    }

    /// The input root's whole content root, every mark folded: one hash for every file,
    /// link, mode, folder and state `input:` holds.
    private func inputRoot() throws -> DataObjectHash {
        try Folder.flushDirtyManifests()
        return try Checkpoints.currentInputRoot()
    }

    private func tree() throws {
        try push("app/main.swift", "print(1)\n")
        try push("app/run.sh", "echo\n", mode: 0o755)
        try push("app/lib/Lib.swift", "struct Lib {}\n")
        try push("app/current", "print(1)\n", link: "main.swift")
        _ = try Folder.pushSymbolicLink(target: "lib", at: Path("app/library"))
        try push("app/library/Lib.swift", "struct Lib {}\n")
    }

    // MARK: - Recording

    func test_aBatchRecordsEachPathOnceWithWhatItHeldBeforeTheBatch() throws {
        try push("app/main.swift", "print(1)\n")
        let before = try BatchJournal.currentRecord(at: Path("app/main.swift"))

        let journal = try BatchJournal(identifier: "test")
        try push("app/main.swift", "print(2)\n", journal: journal)
        try push("app/main.swift", "print(3)\n", journal: journal)
        try push("app/new/File.swift", "new\n", journal: journal)

        let records = try journal.records()
        XCTAssertEqual(records[Path("app/main.swift")], before, "the first record wins")
        XCTAssertEqual(records[Path("app")]?.holdsContent, true)
        XCTAssertEqual(records[Path("app/new")], .absent, "a folder the push makes is on record as absent")
        XCTAssertEqual(records[Path("app/new/File.swift")], .absent)
        XCTAssertEqual(journal.paths.map(\.string), ["app", "app/main.swift", "app/new", "app/new/File.swift"])
    }

    func test_closingTheJournalDropsItsRows() throws {
        let journal = try BatchJournal(identifier: "test")
        try push("app/main.swift", "print(1)\n", journal: journal)
        try journal.close()
        XCTAssertTrue(try journal.records().isEmpty)
        XCTAssertTrue(try DatabaseLayer.shared.metadata.selectEntries(withExactPrefix: BatchJournal.keyPrefix).isEmpty)
    }

    // MARK: - Replaying

    func test_aReplayRestoresChangedFilesModesAndLinks() throws {
        try tree()
        let before = try inputRoot()

        let journal = try BatchJournal(identifier: "test")
        try push("app/main.swift", "print(2)\n", journal: journal)
        try push("app/run.sh", "echo\n", mode: 0o644, journal: journal)
        try push("app/current", "echo\n", link: "run.sh", journal: journal)
        try journal.recordPathAndFoldersAbove(Path("app/library"))
        _ = try Folder.pushSymbolicLink(target: "elsewhere", at: Path("app/library"))
        XCTAssertNotEqual(try inputRoot(), before)

        try journal.replay()
        XCTAssertEqual(try inputRoot(), before)
        XCTAssertTrue(try journal.records().isEmpty, "a replay closes the journal")
    }

    func test_aReplayTakesAwayWhatTheBatchMadeAndBringsBackWhatItRemoved() throws {
        try tree()
        let before = try inputRoot()

        let journal = try BatchJournal(identifier: "test")
        try push("app/new/deep/File.swift", "new\n", journal: journal)
        try remove("app/lib", journal: journal)
        try remove("app/run.sh", journal: journal)
        XCTAssertNotEqual(try inputRoot(), before)

        try journal.replay()
        XCTAssertEqual(try inputRoot(), before)
        XCTAssertNil(try Folder.inputFileSystem.childNode(path: Path("app/new")), "a folder the batch made is gone")
        XCTAssertEqual(try BatchJournal.currentRecord(at: Path("app/lib/Lib.swift")).holdsContent, true)
    }

    func test_aReplayRestoresAFileTheBatchRemovedAndThenPushedAgainAsAFolder() throws {
        try push("app/thing", "a file\n")
        let before = try inputRoot()

        let journal = try BatchJournal(identifier: "test")
        try remove("app/thing", journal: journal)
        try Folder.flushDirtyManifests()
        try engine.processPendingDeletions()
        try push("app/thing/inside.txt", "now a folder\n", journal: journal)
        XCTAssertEqual(try Folder.inputFileSystem.childNode(path: Path("app/thing"))?.kind, Folder.kind)

        try journal.replay()
        XCTAssertEqual(try inputRoot(), before)
        XCTAssertEqual(try Folder.inputFileSystem.childNode(path: Path("app/thing"))?.kind, StaticFile.kind)
    }

    func test_aReplayKeepsAStateThatIsNotAFile() throws {
        try push("app/main.swift", "print(1)\n")
        let removed = try BatchJournal(identifier: "setup")
        try remove("app/main.swift", journal: removed)
        try removed.close()
        let before = try inputRoot()

        let journal = try BatchJournal(identifier: "test")
        try push("app/main.swift", "print(2)\n", journal: journal)
        try journal.replay()

        XCTAssertEqual(try inputRoot(), before, "a removed source comes back removed, not as nothing")
    }

    func test_aJournalOpenedAgainUnderOneIdentifierStartsEmpty() throws {
        let first = try BatchJournal(identifier: "session-1")
        try push("app/main.swift", "print(1)\n", journal: first)
        let second = try BatchJournal(identifier: "session-1")
        XCTAssertTrue(try second.records().isEmpty)
    }
}
