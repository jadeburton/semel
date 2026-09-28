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

    /// A tree of `paths`, each file's content its own path unless `content` says otherwise.
    private func tree(_ paths: [String], content: String? = nil, mode: UInt16 = 0o644) throws -> NodeValue {
        let entries = try paths.map { TreeManifestEntry(path: $0, hash: try (content ?? $0).intern(), mode: mode) }
        return .value(try TreeManifest(entries: entries).toJSON().intern())
    }

    private func process(_ trees: [String: NodeValue]) throws -> NodeValue {
        let node = try TreeMerger(thisNode: NodeRecord(id: 1, kind: TreeMerger.kind))
        let output = try node.process(input: ProcessInput(inputValues: [TreeMerger.inputPort: trees]))
        return try XCTUnwrap(output.outputValues[TreeMerger.outputPort])
    }

    /// What the node publishes when it demands a value it cannot have: the throw reaches the
    /// engine, which writes the state onto every output port.
    private func processCatchingTheState(_ trees: [String: NodeValue]) throws -> NodeValue {
        let node = try TreeMerger(thisNode: NodeRecord(id: 1, kind: TreeMerger.kind))
        let output = node.processWithCatch(input: ProcessInput(inputValues: [TreeMerger.inputPort: trees]))
        return try XCTUnwrap(output.outputValues[TreeMerger.outputPort])
    }

    /// B-77. A package target's resources become a bundle inside an app bundle: the merged
    /// tree is placed under a folder, and a collision is still a collision.
    func test_placesEveryEntryUnderTheFolderNamed() throws {
        let node = try TreeMerger(thisNode: NodeRecord(id: 1, kind: TreeMerger.kind,
                                                       properties: [TreeMerger.underProperty: "Kit_Kit.bundle"]))
        let output = try node.process(input: ProcessInput(inputValues: [TreeMerger.inputPort: [
            "assets": try tree(["Assets.car"]), "strings": try tree(["en.lproj/Localizable.strings"])]]))

        let merged = try XCTUnwrap(output.outputValues[TreeMerger.outputPort])
        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try merged.expectValue().resolveAsString())
        XCTAssertEqual(manifest.entries.map(\.path), ["Kit_Kit.bundle/Assets.car", "Kit_Kit.bundle/en.lproj/Localizable.strings"])
    }

    func test_mergesEveryEntryOfEveryTree() throws {
        let merged = try process(["assets": try tree(["Assets.car", "AppIcon60x60@2x.png"]),
                                  "strings": try tree(["en.lproj/Localizable.strings"])])

        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try merged.expectValue().resolveAsString())
        XCTAssertEqual(manifest.entries.map(\.path), ["AppIcon60x60@2x.png", "Assets.car", "en.lproj/Localizable.strings"])
    }

    /// Two trees holding one path with different content is a mistake in the formula; the
    /// error names the path and both trees, rather than letting the later one win.
    func test_onePathInTwoTreesWithDifferentContentIsAnErrorNamingBoth() throws {
        let merged = try process(["assets": try tree(["Assets.car"], content: "compiled today"),
                                  "more":   try tree(["Assets.car"], content: "compiled yesterday")])

        guard case .noValue(.error(let messageHash)) = merged else {
            return XCTFail("expected an error")
        }
        let message = try messageHash.resolveAsString()
        XCTAssertTrue(message.contains("Assets.car") && message.contains("assets") && message.contains("more"), message)
    }

    /// The same file at one path from two trees is one file, placed once: an app links two
    /// packages that both depend on a third, and each package's tree of bundles carries the
    /// third's (B-77, B-125). The same content under another mode is still two files.
    func test_theSameEntryFromTwoTreesIsPlacedOnce() throws {
        let merged = try process(["bundles_Account":    try tree(["DesignSystem_DesignSystem.bundle/Assets.car", "Account_Account.bundle/a.png"]),
                                  "bundles_AppAccount": try tree(["DesignSystem_DesignSystem.bundle/Assets.car"])])

        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try merged.expectValue().resolveAsString())
        XCTAssertEqual(manifest.entries.map(\.path), ["Account_Account.bundle/a.png", "DesignSystem_DesignSystem.bundle/Assets.car"])

        let differentMode = try process(["one": try tree(["tool"], mode: 0o755), "two": try tree(["tool"], mode: 0o644)])
        guard case .noValue(.error) = differentMode else {
            return XCTFail("expected an error for one path under two modes, got \(differentMode)")
        }
    }

    /// A tree that failed stops the merge, and the merger says that as its own state rather
    /// than repeating the tool's sentence: the failure belongs to the node that failed, and a
    /// report that reads the merger's state folds it onto that node instead of naming both.
    func test_aTreeWithoutAValueStopsTheMergeAsACarriedState() throws {
        let merged = try processCatchingTheState(
            ["assets": try tree(["Assets.car"]),
             "strings": .noValue(reason: .error(messageDataObjectHash: try "xcstringstool failed".intern()))])

        guard case .noValue(.inputInError) = merged else {
            return XCTFail("expected the carried state, got \(merged)")
        }
    }

    /// A tree that has never been produced is not a failure, so what stops the merge is not
    /// one either.
    func test_aTreeThatHasNeverBeenProducedStopsTheMergeWithoutAFailure() throws {
        let merged = try processCatchingTheState(["assets": .noValue(reason: .initializing)])

        guard case .noValue(.inputNotProduced) = merged else {
            return XCTFail("expected the not-produced state, got \(merged)")
        }
    }
}
