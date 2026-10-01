//
//  PushedFilesTests.swift
//  SemelProtocolTests
//
//  The body of a `pushFiles` request: the files' bytes one after another, cut apart again
//  by the headers' lengths alone. Both ends go through `PushedFiles`, so these pin the one
//  rule that says where a file ends.
//

@testable import SemelProtocol
import XCTest

final class PushedFilesTests: XCTestCase {

    private func header(_ path: String, _ content: Data) -> PushedFileHeader {
        PushedFileHeader(path: path, mode: 0o644, length: content.count)
    }

    func test_theBodyIsEachFilesBytesInTurnAndCutsBackIntoThem() throws {
        let contents = [Data("int main() {}".utf8), Data(), Data([0, 255, 10]), Data("x".utf8)]
        let headers  = contents.enumerated().map { header("file\($0.offset)", $0.element) }

        let body = PushedFiles.body(joining: contents)

        XCTAssertEqual(body, Data("int main() {}".utf8) + Data([0, 255, 10]) + Data("x".utf8))
        XCTAssertEqual(try PushedFiles.contents(of: body, by: headers), contents,
                       "an empty file in the middle is still its own, and moves nothing after it")
    }

    func test_aBatchOfNoFilesIsAnEmptyBody() throws {
        XCTAssertEqual(PushedFiles.body(joining: []), Data())
        XCTAssertEqual(try PushedFiles.contents(of: Data(), by: []), [])
    }

    /// The bytes after a header that is one short would all be read as the wrong file's,
    /// so a body the headers do not account for exactly is refused whole.
    func test_aBodyTheHeadersDoNotAccountForIsRefused() {
        let headers = [header("a.c", Data("aa".utf8)), header("b.c", Data("b".utf8))]

        XCTAssertThrowsError(try PushedFiles.contents(of: Data("aab!".utf8), by: headers)) { error in
            XCTAssertEqual(error as? PushedFilesError, .bodyLengthMismatch(declared: 3, actual: 4))
        }
        XCTAssertThrowsError(try PushedFiles.contents(of: Data("aa".utf8), by: headers)) { error in
            XCTAssertEqual(error as? PushedFilesError, .bodyLengthMismatch(declared: 3, actual: 2))
        }
    }

    func test_aNegativeLengthIsRefusedByName() {
        let headers = [PushedFileHeader(path: "a.c", mode: 0o644, length: 2),
                       PushedFileHeader(path: "b.c", mode: 0o644, length: -1)]

        XCTAssertThrowsError(try PushedFiles.contents(of: Data("a".utf8), by: headers)) { error in
            XCTAssertEqual(error as? PushedFilesError, .negativeLength(path: "b.c", length: -1))
        }
    }

    /// A body that arrives as a slice of a larger buffer — as a frame's does — is cut from
    /// its own start, not from the buffer's.
    func test_aBodyThatIsASliceIsCutFromItsOwnStart() throws {
        let buffer = Data("headerhello".utf8)
        let body   = buffer.suffix(from: 6)

        XCTAssertEqual(try PushedFiles.contents(of: body, by: [header("a", Data("he".utf8)), header("b", Data("llo".utf8))]),
                       [Data("he".utf8), Data("llo".utf8)])
    }
}
