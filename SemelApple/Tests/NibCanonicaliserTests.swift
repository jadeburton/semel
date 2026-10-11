//
//  NibCanonicaliserTests.swift
//  SemelAppleTests
//
//  ibtool's nibs in canonical form (B-154): the NIBArchive read and written back as it
//  is, connections in any order coming out as one archive, a rewrite that changed what an
//  object says caught when it is read back, and the canonical nib loading as ibtool's does.
//

import AppKit
@testable import SemelApple
import SemelDatabaseModels
import SemelNodeKit
import XCTest

final class NibCanonicaliserTests: SemelAppleTestCase {

    // MARK: - An archive made here

    private static func data(_ text: String, key: Int) -> NibArchive.Value {
        NibArchive.Value(key: key, type: .data, payload: Array(text.utf8))
    }

    /// The object data of a nib with two outlet connections, the connectors at `first` and
    /// `second` among the objects and listed in the connections array in `order`: what two
    /// runs of ibtool write for one document.
    private static func archive(connectorsAt first: Int, _ second: Int, listed order: [String]) -> NibArchive {
        let keys = ["IB.objectdata", "NSRoot", "NSConnections", "NSClassName", "NSInlinedValue",
                    "UINibEncoderEmptyKey", "NSLabel", "NSSource"].map { Array($0.utf8) }
        let classes = ["NSObject", "NSIBObjectData", "NSCustomObject", "NSMutableArray", "NSNibOutletConnector"]
            .map { NibArchive.ClassName(name: Array($0.utf8) + [0], fallbacks: []) }
        let connector = { (label: String) in
            NibArchive.Object(classIndex: 4, fields: [data(label, key: 6), .referring(to: 2, key: 7)])
        }
        let at = ["delegate": first, "window": second]
        var objects = [
            NibArchive.Object(classIndex: 0, fields: [.referring(to: 1, key: 0)]),
            NibArchive.Object(classIndex: 1, fields: [.referring(to: 2, key: 1), .referring(to: 3, key: 2)]),
            NibArchive.Object(classIndex: 2, fields: [data("NSObject", key: 3)]),
            NibArchive.Object(classIndex: 3, fields: [.init(key: 4, type: .isTrue, payload: [])]
                              + order.compactMap { at[$0] }.map { .referring(to: $0, key: 5) }),
            connector("unused"), connector("unused"),
        ]
        objects[first]  = connector("delegate")
        objects[second] = connector("window")
        return NibArchive(formatVersion: 1, coderVersion: 10, objects: objects, keyTable: keys, classes: classes)
    }

    /// Two archives saying one thing — the same connections, listed and numbered in two
    /// orders — have one canonical form.
    func test_connectionsInAnyOrderComeOutAsOneArchive() throws {
        let one = Self.archive(connectorsAt: 4, 5, listed: ["delegate", "window"])
        let other = Self.archive(connectorsAt: 5, 4, listed: ["window", "delegate"])
        XCTAssertNotEqual(one.bytes(), other.bytes())

        let canonicalOne = try NibCanonicaliser.canonicalBytes(of: one.bytes(), strings: [:])
        let canonicalOther = try NibCanonicaliser.canonicalBytes(of: other.bytes(), strings: [:])

        XCTAssertEqual(canonicalOne, canonicalOther)
        XCTAssertEqual(try NibCanonicaliser.canonicalBytes(of: canonicalOne, strings: [:]), canonicalOne, "a fixed point")
    }

    /// The read-back check catches a rewrite that changed what an object says.
    func test_aCanonicalFormThatSaysSomethingElseIsCaught() throws {
        let original = Self.archive(connectorsAt: 4, 5, listed: ["delegate", "window"])
        let result = try NibCanonicaliser.canonicalise(original)
        var tampered = result.archive
        tampered.objects[tampered.objects.count - 1].fields[0].payload = Array("outlet".utf8)

        XCTAssertThrowsError(try NibCanonicaliser.check(original: original, canonicalBytes: tampered.bytes(),
                                                        newIndex: result.newIndex, strings: [:])) { error in
            guard case NibProblem.readBackDiffers = error else {
                return XCTFail("\(error)")
            }
        }
    }

    /// Not an archive, and cut short: each said by what is wrong.
    func test_aFileThatIsNoArchiveIsRefused() {
        XCTAssertThrowsError(try NibArchive(bytes: Array("bplist00".utf8))) { error in
            XCTAssertEqual(error as? NibProblem, .notANibArchive)
        }
        let bytes = Self.archive(connectorsAt: 4, 5, listed: ["delegate"]).bytes()
        XCTAssertThrowsError(try NibArchive(bytes: Array(bytes.prefix(bytes.count - 3)))) { error in
            guard case NibProblem.truncated = error else {
                return XCTFail("\(error)")
            }
        }
    }

    // MARK: - ibtool's own

    private func compileTiny() throws -> [UInt8] {
        let ibtool = try XCTUnwrap(AppleToolDiscovery.locate("ibtool"))
        let xib = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Interface/Tiny.xib")
        let result = try LocalFileSystemTool(localPath: ibtool).execute(
            arguments: ["--errors", "--target-device", "mac", "--minimum-deployment-target", "13.5", "--compile", "out/Tiny.nib", "Tiny.xib"],
            environment: InterfaceBuilderDaemon.environment,
            inputFiles: [FileNameAndContent(filePath: "Tiny.xib", hash: try DataObjectStore.shared.store(fileAt: xib))],
            expectedOutputFileNames: [],
            expectedOutputFolders: ["out"])
        XCTAssertEqual(result.exitCode, 0, result.printedOutput)
        let nib = try XCTUnwrap(result.outputTrees["out"]?.first { $0.path == "Tiny.nib" })
        return try XCTUnwrap(nib.hash).resolve()
    }

    /// The reader and the writer lay an archive out as ibtool does: what is read is written
    /// back to the same bytes.
    func test_ibtoolsNibReadsAndWritesBackToItsOwnBytes() throws {
        let bytes = try compileTiny()

        XCTAssertEqual(try NibArchive(bytes: bytes).bytes(), bytes)
    }

    /// The canonical nib loads as ibtool's does: AppKit instantiates both to the same
    /// top-level objects, the window with its button and text field.
    func test_theCanonicalNibLoadsAsIbtoolsDoes() throws {
        let bytes = try compileTiny()
        let canonical = try NibCanonicaliser.canonicalBytes(of: bytes, strings: [:])

        func topLevel(_ nibBytes: [UInt8]) throws -> [String] {
            let nib = NSNib(nibData: Data(nibBytes), bundle: nil)
            var objects: NSArray?
            XCTAssertTrue(nib.instantiate(withOwner: nil, topLevelObjects: &objects))
            let window = try XCTUnwrap(objects?.compactMap { $0 as? NSWindow }.first)
            defer { window.close() }
            let subviews = window.contentView?.subviews.map { String(describing: type(of: $0)) }.sorted() ?? []
            return (objects ?? []).map { String(describing: type(of: $0)) }.sorted() + subviews + [window.title]
        }
        XCTAssertEqual(try topLevel(canonical), try topLevel(bytes))
        XCTAssertTrue(try topLevel(canonical).contains("NSButton"))
    }

    /// A storyboard's UUIDs are derived from the document and the identifier: the same for
    /// one storyboard every time, another for another.
    func test_aStoryboardsUUIDsAreDerivedFromWhatTheyName() {
        let one = NibCanonicaliser.derivedUUID(document: "Main.storyboard", identifier: "Progress")
        XCTAssertEqual(one, NibCanonicaliser.derivedUUID(document: "Main.storyboard", identifier: "Progress"))
        XCTAssertNotEqual(one, NibCanonicaliser.derivedUUID(document: "Other.storyboard", identifier: "Progress"))
        XCTAssertNotNil(UUID(uuidString: one))
        XCTAssertEqual(one.count, 36)
    }
}
