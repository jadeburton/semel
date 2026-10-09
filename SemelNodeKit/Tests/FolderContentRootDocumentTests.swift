//
//  FolderContentRootDocumentTests.swift
//  SemelNodeKitTests
//
//  B-143. A failed lock names what the comparison left out by reading the folder's whole
//  root back through the documents it names, so the reader has to be the writer's exact
//  inverse — framing included, for a name or a link's target holding a tab or a newline.
//

@testable import SemelNodeKit
import XCTest

final class FolderContentRootDocumentTests: XCTestCase {

    func test_aDocumentReadsBackAsTheLinesItWasWrittenFrom() throws {
        let lines: [FolderContentRoot.Line] = [
            ("Code.swift", .file, .file(hash: "aa11", mode: 0o644)),
            ("tool", .file, .file(hash: "bb22", mode: 0o4755)),
            ("Sources", .folder, .hash("cc33")),
            ("Current", .link, .symbolicLinkTarget("A\twith tab\nand newline")),
            ("new\nline\tname", .file, .notProduced),
            ("gone.swift", .file, .deleted),
            ("broken", .file, .failed),
            ("product", .other, .notFolded),
            ("caf\u{E9}", .file, .file(hash: "dd44", mode: 0o600)),
        ]
        let document = FolderContentRoot.document(of: lines)

        let read = try XCTUnwrap(FolderContentRoot.lines(ofDocument: document))

        XCTAssertEqual(FolderContentRoot.document(of: read), document)
        XCTAssertEqual(read.count, lines.count)
    }

    func test_textThatIsNotADocumentReadsAsNone() {
        XCTAssertNil(FolderContentRoot.lines(ofDocument: "not a content root\n"))
        XCTAssertNil(FolderContentRoot.lines(ofDocument: "\(FolderContentRoot.formatTag)\nfile\thash x\t9\tshort\n"))
        XCTAssertEqual(FolderContentRoot.lines(ofDocument: FolderContentRoot.document(of: []))?.count, 0)
    }
}
