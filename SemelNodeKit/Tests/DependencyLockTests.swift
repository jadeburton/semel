//
//  DependencyLockTests.swift
//  SemelNodeKitTests
//
//  B-06. The lock beside a vendored dependency is written by `semel-swift prepare` and read
//  by the converter, and edited by hand in between; its text is the one place the two
//  agree, so the round trip and the refusals are what is pinned.
//

@testable import SemelNodeKit
import XCTest

final class DependencyLockTests: XCTestCase {

    private let grdb = DependencyLock(contentRoot: "8b1a9953c4611296a827abf8c47804d7e6c49c6b0000000000000000000000ab",
                                      fold:        FolderContentRoot.formatTag,
                                      version:     "7.11.1",
                                      revision:    "b83108d10f42680d78f23fe4d4d80fc88dab3212",
                                      origin:      "https://github.com/groue/GRDB.swift.git")

    // MARK: - The text

    func test_aLockReadsBackAsTheLockThatWasWritten() throws {
        XCTAssertEqual(try DependencyLock.parse(grdb.text), grdb)
    }

    func test_aLockWithOnlyItsEnforcedLinesReadsBack() throws {
        let bare = DependencyLock(contentRoot: "abc123", fold: FolderContentRoot.formatTag)

        XCTAssertEqual(try DependencyLock.parse(bare.text), bare)
        XCTAssertFalse(bare.text.contains("version"), "a line with nothing to say is left out, got:\n\(bare.text)")
    }

    /// The shape B-06 sketches, which is what a reviewer reads in a diff: a key column, the
    /// content root named with its hash.
    func test_theTextIsOneKeyAndValuePerLineUnderAHeading() {
        let lines = grdb.text.components(separatedBy: "\n")

        XCTAssertTrue(lines[0].hasPrefix("#"), "got:\n\(grdb.text)")
        XCTAssertEqual(lines[1], "content   sha256:\(grdb.contentRoot)")
        XCTAssertEqual(lines[2], "fold      \(FolderContentRoot.formatTag)")
        XCTAssertEqual(lines[3], "version   7.11.1")
        XCTAssertEqual(lines[5], "origin    https://github.com/groue/GRDB.swift.git")
    }

    /// A package with binary targets records each download's checksum on one line (B-77),
    /// the column widened for it; a package with none reads as a lock always did.
    func test_theArtifactsChecksumsAreOneLineSortedByTarget() throws {
        var sparkle = grdb
        sparkle.artifacts = ["Sparkle": "4d5de3d3", "Other": "9e1f"]

        XCTAssertEqual(try DependencyLock.parse(sparkle.text), sparkle)
        let lines = sparkle.text.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], "content    sha256:\(grdb.contentRoot)")
        XCTAssertEqual(lines[6], "artifacts  Other=9e1f,Sparkle=4d5de3d3")
        XCTAssertFalse(grdb.text.contains("artifacts"), grdb.text)
    }

    func test_anArtifactItemThatIsNotTargetEqualsChecksumIsRefused() {
        XCTAssertThrowsError(try DependencyLock.parse("content sha256:abc\nfold x\nartifacts Sparkle\n")) { error in
            XCTAssertEqual(error as? DependencyLockError, .malformedArtifact("Sparkle"))
        }
    }

    /// The dot-named resources a lock covers are one `hidden` line each, sorted, the one key
    /// said more than once; a lock with none reads as a lock always did (B-143).
    func test_theHiddenFilesAreOneLineEachSorted() throws {
        var withHidden = grdb
        withHidden.hiddenFiles = ["Sources/Kit/.config", ".env"].sorted()

        XCTAssertEqual(try DependencyLock.parse(withHidden.text), withHidden)
        let lines = withHidden.text.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines[6...7]), ["hidden    .env", "hidden    Sources/Kit/.config"])
        XCTAssertFalse(grdb.text.contains("hidden"), grdb.text)
        XCTAssertEqual(withHidden.hiddenFilesByFolder(under: Path("Dependencies/GRDB.swift")),
                       ["Dependencies/GRDB.swift": [".env"], "Dependencies/GRDB.swift/Sources/Kit": [".config"]])
    }

    /// A `hidden` line names a dot-named file a push can send by its name: never a path
    /// through a dot-named folder, never one climbing out, never a plain name, never twice.
    func test_aHiddenPathAPushCannotSendIsRefused() {
        for path in [".git/config", "../.env", "/abs/.env", "Sources/plain", "Sources//.env", "."] {
            XCTAssertThrowsError(try DependencyLock.parse("content sha256:abc\nfold x\nhidden \(path)\n"), path) { error in
                XCTAssertEqual(error as? DependencyLockError, .malformedHiddenFile(path, line: 3))
            }
        }
        XCTAssertThrowsError(try DependencyLock.parse("content sha256:abc\nfold x\nhidden .env\nhidden .env\n")) { error in
            XCTAssertEqual(error as? DependencyLockError, .malformedHiddenFile(".env", line: 4))
        }
    }

    func test_blankLinesCommentsAndExtraSpacesAreFree() throws {
        let text = """

            # hand-edited
              content    sha256:abc123
            fold semel-folder-content-root 2

            """

        XCTAssertEqual(try DependencyLock.parse(text), DependencyLock(contentRoot: "abc123", fold: "semel-folder-content-root 2"))
    }

    // MARK: - Refusals

    func test_aLockWithNoContentLineIsRefused() {
        XCTAssertThrowsError(try DependencyLock.parse("fold x\nversion 1.0\n")) { error in
            XCTAssertEqual(error as? DependencyLockError, .missingKey("content"))
        }
    }

    func test_aLockWithNoFoldLineIsRefused() {
        XCTAssertThrowsError(try DependencyLock.parse("content sha256:abc\n")) { error in
            XCTAssertEqual(error as? DependencyLockError, .missingKey("fold"))
        }
    }

    /// A misspelt key would otherwise be a line nobody reads.
    func test_anUnknownKeyIsRefusedByItsLine() {
        XCTAssertThrowsError(try DependencyLock.parse("content sha256:abc\nfold x\nverison 1.0\n")) { error in
            XCTAssertEqual(error as? DependencyLockError, .unknownKey("verison", line: 3))
            XCTAssertTrue(String(describing: error).contains("line 3"), "got \(error)")
        }
    }

    func test_aKeySaidTwiceIsRefused() {
        XCTAssertThrowsError(try DependencyLock.parse("content sha256:abc\ncontent sha256:def\nfold x\n")) { error in
            XCTAssertEqual(error as? DependencyLockError, .repeatedKey("content", line: 2))
        }
    }

    func test_aContentRootWithoutItsHashNameIsRefused() {
        XCTAssertThrowsError(try DependencyLock.parse("content abc\nfold x\n")) { error in
            XCTAssertEqual(error as? DependencyLockError, .unknownContentScheme("abc"))
        }
    }

    func test_aKeyWithNoValueIsRefused() {
        XCTAssertThrowsError(try DependencyLock.parse("content sha256:abc\nfold x\nversion\n")) { error in
            XCTAssertEqual(error as? DependencyLockError, .emptyValue("version", line: 3))
        }
    }

    // MARK: - Where it lives

    func test_theLockIsBesideTheFolderItLocks() {
        XCTAssertEqual(DependencyLock.lockPath(forDependencyAt: "input:/repo/Dependencies/GRDB.swift"),
                       "input:/repo/Dependencies/GRDB.swift.semel-lock")
        XCTAssertEqual(DependencyLock.lockFile(forDependencyAt: URL(fileURLWithPath: "/tmp/repo/Dependencies/GRDB.swift")).path,
                       "/tmp/repo/Dependencies/GRDB.swift.semel-lock")
    }

    func test_aRepositoryIsVendoredUnderItsLastPathComponentWithoutGit() {
        XCTAssertEqual(DependencyLock.folderName(forRepositoryURL: "https://github.com/groue/GRDB.swift.git"), "GRDB.swift")
        XCTAssertEqual(DependencyLock.folderName(forRepositoryURL: "https://github.com/kean/Nuke/"), "Nuke")
        XCTAssertEqual(DependencyLock.folderName(forRepositoryURL: "git@github.com:groue/GRDB.swift.git"), "GRDB.swift")
        XCTAssertNil(DependencyLock.folderName(forRepositoryURL: "https://example.com/.git"))
    }
}
