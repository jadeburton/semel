//
//  PushInternerTests.swift
//  SemelServerTests
//
//  The part of a push that runs before the handler's queue, on every core: cutting the
//  body into files, hashing each and writing it to the object store. What the queue is
//  handed must be what `intern()` on the queue would have given it, in the order sent.
//

@testable import SemelServer
import SemelNodeKit
import SemelProtocol
import XCTest

final class PushInternerTests: RequestHandlerTestCase {

    private func batch(_ files: [(path: String, mode: UInt16, text: String)]) -> ([PushedFileHeader], Data) {
        let contents = files.map { Data($0.text.utf8) }
        let headers  = zip(files, contents).map { PushedFileHeader(path: $0.path, mode: $0.mode, length: $1.count) }
        return (headers, PushedFiles.body(joining: contents))
    }

    func test_eachFileIsStoredUnderTheHashItsBytesInternTo() throws {
        let (headers, body) = batch([("src/main.c", 0o644, "int main() {}"), ("run.sh", 0o755, "echo hi")])

        let interned = try PushInterner.intern(headers, body: body)

        XCTAssertEqual(interned, [
            InternedFile(path: "src/main.c", mode: 0o644, contentHash: Array("int main() {}".utf8).internedHash),
            InternedFile(path: "run.sh", mode: 0o755, contentHash: Array("echo hi".utf8).internedHash),
        ])
        for (file, text) in zip(interned, ["int main() {}", "echo hi"]) {
            XCTAssertEqual(try file.contentHash.resolveAsString(), text, "the bytes are in the store under the hash")
        }
    }

    /// Hundreds of files across every core come back in the order they were sent, each
    /// with its own hash.
    func test_manyFilesComeBackInTheOrderTheyWereSent() throws {
        let files = (0..<300).map { (path: "tree/file\($0).txt", mode: UInt16(0o644), text: "content \($0)") }
        let (headers, body) = batch(files)

        let interned = try PushInterner.intern(headers, body: body)

        XCTAssertEqual(interned.map(\.path), files.map(\.path))
        XCTAssertEqual(interned.map(\.contentHash), files.map { Array($0.text.utf8).internedHash })
    }

    /// Two files with the same bytes race to one object; both are named by it, and it holds
    /// the bytes once.
    func test_twoFilesWithTheSameBytesShareOneObject() throws {
        let (headers, body) = batch((0..<16).map { (path: "copy\($0).h", mode: UInt16(0o644), text: "#pragma once") })

        let interned = try PushInterner.intern(headers, body: body)

        XCTAssertEqual(Set(interned.map(\.contentHash)).count, 1)
        XCTAssertEqual(DataObjectStore.shared.allHashes(), [Array("#pragma once".utf8).internedHash])
    }

    /// An empty file is the empty hash, as `intern()` names it, and stores nothing.
    func test_anEmptyFileIsTheEmptyHashAndStoresNothing() throws {
        let (headers, body) = batch([("empty.txt", 0o644, "")])

        XCTAssertEqual(try PushInterner.intern(headers, body: body).map(\.contentHash), [""])
        XCTAssertEqual(DataObjectStore.shared.allHashes(), [])
    }

    /// A body the headers do not account for is refused before a byte of it is stored.
    func test_aBodyTheHeadersDoNotAccountForStoresNothing() {
        let (headers, body) = batch([("a.c", 0o644, "aa"), ("b.c", 0o644, "bb")])

        XCTAssertThrowsError(try PushInterner.intern(headers, body: body + Data("!".utf8))) { error in
            XCTAssertEqual(error as? PushedFilesError, .bodyLengthMismatch(declared: 4, actual: 5))
        }
        XCTAssertEqual(DataObjectStore.shared.allHashes(), [])
    }
}
