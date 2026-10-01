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

    // MARK: - push, several files to a request

    private func batch(_ files: [(path: String, mode: UInt16, text: String)]) -> (DaemonRequest, Data) {
        let contents = files.map { Data($0.text.utf8) }
        let headers  = zip(files, contents).map { PushedFileHeader(path: $0.path, mode: $0.mode, length: $1.count) }
        return (.pushFiles(files: headers), PushedFiles.body(joining: contents))
    }

    func test_aBatchStoresEachFileAndSaysWhetherEachChanged() throws {
        try daemon(.pushFile(path: "src/old.c", mode: 0o644), body: Data("old".utf8))
        let (request, body) = batch([("src/main.c", 0o644, "int main() {}"), ("src/old.c", 0o644, "old"),
                                     ("run.sh", 0o755, "echo")])

        XCTAssertEqual(try daemon(request, body: body).0,
                       .pushFiles(outcomes: [.stored(didChange: true), .stored(didChange: false), .stored(didChange: true)]))
        XCTAssertEqual(try daemon(.fetch(fileSystem: .input, path: "src/main.c")).1, Data("int main() {}".utf8))
        XCTAssertEqual(try daemon(.fetch(fileSystem: .input, path: "run.sh")).0, .fetch(mode: 0o755))
        XCTAssertEqual(try daemon(request, body: body).0,
                       .pushFiles(outcomes: [.stored(didChange: false), .stored(didChange: false), .stored(didChange: false)]),
                       "the same batch again changes nothing")
    }

    /// B-130. A file the graph refuses is answered as its own push would have been, and the
    /// files after it are stored all the same — whether the refusal comes on the way to the
    /// file (a file named as a folder) or from making it (a file where a folder is).
    func test_aFileOfABatchTheGraphRefusesFailsAloneAndTheRestAreStored() throws {
        try daemon(.pushFolder(path: "src/lib"))
        let (request, body) = batch([("src/a.c", 0o644, "a"), ("src/a.c/b.c", 0o644, "b"), ("src/lib", 0o644, "lib"),
                                     ("src/c.c", 0o644, "c")])

        guard case .pushFiles(let outcomes) = try daemon(request, body: body).0 else {
            return XCTFail("expected the batch's outcomes")
        }

        XCTAssertEqual(outcomes.count, 4)
        XCTAssertEqual(outcomes[0], .stored(didChange: true))
        guard case .failed(.nodeError) = outcomes[1], case .failed(.nodeError) = outcomes[2] else {
            return XCTFail("expected both refusals as node errors, got \(outcomes)")
        }
        XCTAssertEqual(outcomes[3], .stored(didChange: true))
        XCTAssertEqual(try daemon(.fetch(fileSystem: .input, path: "src/c.c")).1, Data("c".utf8))
        let (_, findings) = try daemon(.check)
        XCTAssertEqual(try MessageCoder.decode([CheckFinding].self, from: try XCTUnwrap(findings)), [],
                       "a refused file leaves no half-made node behind")
    }

    /// The batch is one transaction with each file's own transactions kept inside it, so
    /// the graph it leaves is the one pushing each file alone leaves — refused files too.
    func test_aBatchLeavesTheGraphThatPushingEachFileAloneLeaves() throws {
        let files: [(path: String, mode: UInt16, text: String)] = [
            ("src/main.c", 0o644, "int main() {}"),
            ("src/lib/util.c", 0o644, "int util;"),
            ("src/main.c/inner.c", 0o644, "a file named as a folder"),
            ("src/lib", 0o644, "a file where a folder is"),
            ("run.sh", 0o755, "echo"),
            ("empty.txt", 0o644, ""),
        ]
        for file in files {
            _ = try? StaticFile.push(Array(file.text.utf8), mode: file.mode, at: Path(file.path))
        }
        let pushedAlone = try engine.graphDescription()

        tearDown()
        try setUpWithError()
        let (request, body) = batch(files)
        try daemon(request, body: body)

        XCTAssertEqual(try engine.graphDescription(), pushedAlone)
    }

    /// A body the headers do not account for byte for byte is the request's fault, and
    /// nothing of it is stored.
    func test_aBatchWhoseBodyTheHeadersDoNotAccountForIsMalformedAndStoresNothing() throws {
        let (request, body) = batch([("a.c", 0o644, "aa"), ("b.c", 0o644, "bb")])
        let root           = try engine.inputFileSystem
        let storedBefore   = Set(DataObjectStore.shared.allHashes())

        guard case .malformedRequest = daemonError(request, body: body + Data("!".utf8)) else {
            return XCTFail("expected a malformed request")
        }
        XCTAssertNil(try root.childNode(path: Path("a.c")))
        XCTAssertEqual(Set(DataObjectStore.shared.allHashes()), storedBefore)
    }

    /// A single file the graph refuses is still the request's own error, as it was.
    func test_aSingleFileTheGraphRefusesIsAnErrorReply() throws {
        try daemon(.pushFile(path: "src/a.c", mode: 0o644), body: Data("a".utf8))

        guard case .nodeError = daemonError(.pushFile(path: "src/a.c/b.c", mode: 0o644), body: Data("b".utf8)) else {
            return XCTFail("expected a node error")
        }
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
