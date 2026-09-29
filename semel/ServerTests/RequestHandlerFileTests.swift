//
//  RequestHandlerFileTests.swift
//  SemelServerTests
//
//  The file verbs against a real in-memory graph: what the CLI's push, ls, rm and cp
//  become once the graph is on the other side of a wire.
//

@testable import SemelCore
@testable import SemelServer
import SemelDatabaseModels
import SemelNodeKit
import SemelProtocol
import XCTest

final class RequestHandlerFileTests: RequestHandlerTestCase {

    // MARK: - push

    func test_pushFileCreatesTheFileAndItsFoldersAndReportsChange() throws {
        let (response, _) = try daemon(.pushFile(path: "src/main.c", mode: 0o644), body: Data("int main() {}".utf8))

        XCTAssertEqual(response, .pushFile(didChange: true))
        let root = try engine.inputFileSystem
        XCTAssertNotNil(try root.childNode(path: Path("src")))
        XCTAssertNotNil(try root.childNode(path: Path("src/main.c")))
    }

    func test_pushingTheSameBytesTwiceReportsNoChange() throws {
        try daemon(.pushFile(path: "a.c", mode: 0o644), body: Data("x".utf8))

        let (response, _) = try daemon(.pushFile(path: "a.c", mode: 0o644), body: Data("x".utf8))

        XCTAssertEqual(response, .pushFile(didChange: false))
    }

    /// B-108. The mode is stored beside the bytes, so a tree or a product built from the
    /// file keeps it — and a file made executable is a change even when its bytes are not.
    func test_pushKeepsTheModeAndAChangedModeIsAChange() throws {
        try daemon(.pushFile(path: "run.sh", mode: 0o644), body: Data("echo".utf8))

        let (response, _) = try daemon(.pushFile(path: "run.sh", mode: 0o755), body: Data("echo".utf8))

        XCTAssertEqual(response, .pushFile(didChange: true))
        XCTAssertEqual(try daemon(.fetch(fileSystem: .input, path: "run.sh")).0, .fetch(mode: 0o755))
    }

    /// B-77. A link to a file is a file holding the bytes it names, whose metadata says what
    /// it holds, and `fetch` answers the link; a link to a folder is a pinned folder saying
    /// so on its port. Pushed again as it was, neither changes.
    func test_aSymbolicLinkIsStoredAsOneAndFetchedAsOne() throws {
        let (fileLink, _) = try daemon(.pushSymbolicLink(path: "fw/Tiny", target: "Versions/Current/Tiny", referent: .file(mode: 0o755)),
                                       body: Data("binary".utf8))
        let (folderLink, _) = try daemon(.pushSymbolicLink(path: "fw/Versions/Current", target: "A", referent: .folder))

        XCTAssertEqual(fileLink, .pushFile(didChange: true))
        XCTAssertEqual(folderLink, .pushFile(didChange: true))
        let (fetched, body) = try daemon(.fetch(fileSystem: .input, path: "fw/Tiny"))
        XCTAssertEqual(fetched, .symbolicLink(target: "Versions/Current/Tiny"))
        XCTAssertNil(body)
        let file = try XCTUnwrap(try engine.inputFileSystem.childNode(path: Path("fw/Tiny"))?.nodeAsAny() as? StaticFile)
        XCTAssertEqual(try file.read().map { try $0.expectValue().resolveAsString() }, "binary", "what reads the bytes reads what it names")
        let folder = try XCTUnwrap(try engine.inputFileSystem.childNode(path: Path("fw/Versions/Current")))
        XCTAssertEqual(try folder.readFromOutputPort(Folder.symbolicLinkOutputPort).expectValue().resolveAsString(), "A")
        XCTAssertTrue(try XCTUnwrap(folder.nodeAsAny() as? Folder).isPinned)

        XCTAssertEqual(try daemon(.pushSymbolicLink(path: "fw/Tiny", target: "Versions/Current/Tiny", referent: .file(mode: 0o755)),
                                  body: Data("binary".utf8)).0, .pushFile(didChange: false))
        XCTAssertEqual(try daemon(.pushSymbolicLink(path: "fw/Versions/Current", target: "A", referent: .folder)).0,
                       .pushFile(didChange: false))
    }

    func test_pushFolderCreatesAPinnedFolder() throws {
        let (response, _) = try daemon(.pushFolder(path: "src/lib"))

        XCTAssertEqual(response, .ok)
        XCTAssertNotNil(try engine.inputFileSystem.childNode(path: Path("src/lib")))
    }

    // MARK: - list

    // A node with no consumer is unreferenced, and no processing loop runs in these
    // tests, so nothing ever wires one: the status below is the lister's, not the
    // handler's.

    func test_listReturnsFilesAndFoldersWithSizeAndMode() throws {
        try daemon(.pushFolder(path: "src"))
        try daemon(.pushFile(path: "src/main.c", mode: 0o644), body: Data("int main() {}".utf8))

        let (response, _) = try daemon(.list(fileSystem: .input, pattern: "src/*"))

        XCTAssertEqual(response, .list(entries: [
            ListEntry(path: "src/main.c", kind: .file, size: 13, mode: 0o644, status: .unreferenced),
        ]))
    }

    func test_listOfAFolderPatternReturnsTheFolderItself() throws {
        try daemon(.pushFolder(path: "src"))

        let (response, _) = try daemon(.list(fileSystem: .input, pattern: "src"))

        XCTAssertEqual(response, .list(entries: [ListEntry(path: "src", kind: .folder, size: nil, mode: nil, status: .unreferenced)]))
    }

    func test_listOfNothingIsEmpty() throws {
        XCTAssertEqual(try daemon(.list(fileSystem: .input, pattern: "nope")).0, .list(entries: []))
    }

    // MARK: - remove

    func test_removeDeletesMatchingFilesAndNamesThem() throws {
        try daemon(.pushFile(path: "a.c", mode: 0o644), body: Data("a".utf8))
        try daemon(.pushFile(path: "b.c", mode: 0o644), body: Data("b".utf8))

        let (response, _) = try daemon(.remove(pattern: "*.c"))

        guard case .remove(let removed, let removedFolders) = response else {
            return XCTFail("expected remove, got \(response)")
        }
        XCTAssertEqual(removed.sorted(), ["a.c", "b.c"])
        XCTAssertEqual(removedFolders, [], "a pattern with a dot matches no folder here")
        // A removed file lingers as a ghost with no content until the collector reaches it,
        // which `list` reports as the state a removal leaves and not as a failure.
        let (listed, _) = try daemon(.list(fileSystem: .input, pattern: "*.c"))
        guard case .list(let entries) = listed else {
            return XCTFail("expected list, got \(listed)")
        }
        XCTAssertFalse(entries.isEmpty, "the ghosts are what is being checked")
        XCTAssertTrue(entries.allSatisfy { $0.status == .deleted }, "\(entries)")
    }

    /// The two lists are what the client reports from, so a removed folder has to arrive
    /// as a folder rather than as one more path.
    func test_removeReportsAFolderApartFromItsFiles() throws {
        try daemon(.pushFile(path: "src/a.c", mode: 0o644), body: Data("a".utf8))

        let (response, _) = try daemon(.remove(pattern: "src"))

        XCTAssertEqual(response, .remove(removedFiles: [], removedFolders: ["src"]))
    }

    func test_removeOfNothingReturnsNoPaths() throws {
        XCTAssertEqual(try daemon(.remove(pattern: "nope")).0, .remove(removedFiles: [], removedFolders: []))
    }

    // MARK: - fetch

    func test_fetchReturnsTheBytesAndMode() throws {
        try daemon(.pushFile(path: "a.c", mode: 0o644), body: Data("hello".utf8))

        let (response, body) = try daemon(.fetch(fileSystem: .input, path: "a.c"))

        XCTAssertEqual(response, .fetch(mode: FileMetadata.defaultMode))
        XCTAssertEqual(body, Data("hello".utf8))
    }

    func test_fetchOfAMissingPathIsPathNotFound() {
        XCTAssertEqual(daemonError(.fetch(fileSystem: .input, path: "nope")), .pathNotFound(path: "nope"))
    }

    func test_fetchOfAFolderIsNotAFile() throws {
        try daemon(.pushFolder(path: "src"))

        XCTAssertEqual(daemonError(.fetch(fileSystem: .input, path: "src")),
                       .nodeError(description: "Object src is not a file"))
    }
}
