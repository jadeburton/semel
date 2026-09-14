//
//  TreeMergerTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// B-63. A formula names one tree product per folder, and a bundle folder collects what
/// several tools wrote, so trees have to become one first.
final class TreeMergerTests: SemelCoreTestCase {

    private func tree(_ paths: [String]) throws -> NodeValue {
        let entries = try paths.map { TreeManifestEntry(path: $0, hash: try $0.intern(), mode: 0o644) }
        return .value(try TreeManifest(entries: entries).toJSON().intern())
    }

    private func process(_ trees: [String: NodeValue]) throws -> NodeValue {
        let node = try TreeMerger(thisNode: NodeRecord(id: 1, kind: TreeMerger.kind))
        let output = try node.process(input: ProcessInput(inputValues: [TreeMerger.inputPort: trees]))
        return try XCTUnwrap(output.outputValues[TreeMerger.outputPort])
    }

    func test_mergesEveryEntryOfEveryTree() throws {
        let merged = try process(["assets": try tree(["Assets.car", "AppIcon60x60@2x.png"]),
                                  "strings": try tree(["en.lproj/Localizable.strings"])])

        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try merged.expectValue().resolveAsString())
        XCTAssertEqual(manifest.entries.map(\.path), ["AppIcon60x60@2x.png", "Assets.car", "en.lproj/Localizable.strings"])
    }

    /// Two trees holding one path is a mistake in the formula; the error names the path
    /// and both trees, rather than letting the later one win.
    func test_onePathInTwoTreesIsAnErrorNamingBoth() throws {
        let merged = try process(["assets": try tree(["Assets.car"]), "more": try tree(["Assets.car"])])

        guard case .noValue(.error(let messageHash)) = merged else {
            return XCTFail("expected an error")
        }
        let message = try messageHash.resolveAsString()
        XCTAssertTrue(message.contains("Assets.car") && message.contains("assets") && message.contains("more"), message)
    }

    func test_aTreeWithoutAValueStopsTheMergeWithItsReason() throws {
        let merged = try process(["assets": try tree(["Assets.car"]),
                                  "strings": .noValue(reason: .error(messageDataObjectHash: try "xcstringstool failed".intern()))])

        guard case .noValue(.error(let messageHash)) = merged else {
            return XCTFail("expected the tool's error")
        }
        XCTAssertEqual(try messageHash.resolveAsString(), "xcstringstool failed")
    }
}
