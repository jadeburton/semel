//
//  TreeBuilderTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// The counterpart of `TreeFile`: N files in, one tree out, each entry named by its wire.
final class TreeBuilderTests: SemelCoreTestCase {

    private func process(_ files: [String: NodeValue]) throws -> NodeValue {
        let node = try TreeBuilder(thisNode: NodeRecord(id: 1, kind: TreeBuilder.kind))
        let output = try node.process(input: ProcessInput(inputValues: [TreeBuilder.inputPort: files]))
        return try XCTUnwrap(output.outputValues[TreeBuilder.outputPort])
    }

    func test_everyWireBecomesAnEntryNamedByItsKey() throws {
        let built = try process(["Models.o": .value(try "models".intern()),
                                 "Timeline.o": .value(try "timeline".intern())])

        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try built.expectValue().resolveAsString())
        XCTAssertEqual(manifest.entries.map(\.path), ["Models.o", "Timeline.o"])
        XCTAssertEqual(try manifest.entry(at: "Timeline.o")?.hash.resolveAsString(), "timeline")
    }

    /// A file that failed stops the tree, and the tree says so as its own state rather than
    /// repeating the compiler's sentence: a report folds it onto the node that failed.
    func test_aFileWithoutAValueStopsTheTreeAsACarriedState() throws {
        let node = try TreeBuilder(thisNode: NodeRecord(id: 1, kind: TreeBuilder.kind))
        let output = node.processWithCatch(input: ProcessInput(inputValues: [TreeBuilder.inputPort: [
            "Models.o": .value(try "models".intern()),
            "Timeline.o": .noValue(reason: .error(messageDataObjectHash: try "compile failed".intern())),
        ]]))

        guard case .noValue(.inputInError) = try XCTUnwrap(output.outputValues[TreeBuilder.outputPort]) else {
            return XCTFail("expected the carried state")
        }
    }

    func test_noWiresIsAnEmptyTree() throws {
        let built = try process([:])

        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try built.expectValue().resolveAsString())
        XCTAssertTrue(manifest.entries.isEmpty)
    }
}
