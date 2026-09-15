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

    func test_aFileWithoutAValueStopsTheTreeWithItsReason() throws {
        let built = try process(["Models.o": .value(try "models".intern()),
                                 "Timeline.o": .noValue(reason: .error(messageDataObjectHash: try "compile failed".intern()))])

        guard case .noValue(.error(let messageHash)) = built else {
            return XCTFail("expected the compiler's error")
        }
        XCTAssertEqual(try messageHash.resolveAsString(), "compile failed")
    }

    func test_noWiresIsAnEmptyTree() throws {
        let built = try process([:])

        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: try built.expectValue().resolveAsString())
        XCTAssertTrue(manifest.entries.isEmpty)
    }
}
