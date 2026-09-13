//
//  RequestHandlerFileTests.swift
//  SemelServTests
//
//  The file verbs against a real in-memory graph: what the CLI's push, ls, rm and cp
//  become once the graph is on the other side of a wire.
//

@testable import SemelCore
@testable import SemelServ
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

        guard case .remove(let removed) = response else {
            return XCTFail("expected remove, got \(response)")
        }
        XCTAssertEqual(removed.sorted(), ["a.c", "b.c"])
        // A removed file lingers as a ghost with no content, which `list` reports as missing.
        let (listed, _) = try daemon(.list(fileSystem: .input, pattern: "*.c"))
        guard case .list(let entries) = listed else {
            return XCTFail("expected list, got \(listed)")
        }
        XCTAssertTrue(entries.allSatisfy { $0.status == .missing || $0.status == .error }, "\(entries)")
    }

    func test_removeOfNothingReturnsNoPaths() throws {
        XCTAssertEqual(try daemon(.remove(pattern: "nope")).0, .remove(removedPaths: []))
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
