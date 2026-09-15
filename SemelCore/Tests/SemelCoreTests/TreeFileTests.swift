//
//  TreeFileTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// B-63. A tree port carries N files in one manifest; `TreeFile` puts one of them on a
/// port of its own, content and mode, so the rest of the graph never has to know.
final class TreeFileTests: SemelCoreTestCase {

    private func tree(_ files: [(String, String, UInt16)]) throws -> NodeValue {
        let entries = try files.map { TreeManifestEntry(path: $0.0, hash: try $0.1.intern(), mode: $0.2) }
        return .value(try TreeManifest(entries: entries).toJSON().intern())
    }

    private func process(name: String, tree: NodeValue) throws -> ProcessOutput {
        let node = NodeRecord(id: 1, kind: TreeFile.kind, name: nil,
                              properties: [TreeFile.nameProperty: name], scheduled: false, graphSpec: nil)
        return try TreeFile(thisNode: node).process(input: ProcessInput(inputValues: [
            TreeFile.treeInputPort: ["tree": tree],
        ]))
    }

    func test_putsTheNamedEntrysContentAndModeOnItsPorts() throws {
        let output = try process(name: "en.lproj/Localizable.strings",
                                 tree: try tree([("Assets.car", "car", 0o644),
                                                 ("en.lproj/Localizable.strings", "\"hello\" = \"hello\";", 0o755)]))

        XCTAssertEqual(try output.outputValues[TreeFile.outputPort]?.expectValue().resolveAsString(),
                       "\"hello\" = \"hello\";")
        let metadata = try output.outputValues[FileMetadata.portName]?.expectValue().resolveAsString()
        XCTAssertEqual(FileMetadata.decode(from: try XCTUnwrap(metadata))?.mode, 0o755)
    }

    /// The error says what the tree does hold: a wrong name is a formula or converter
    /// mistake, and the list is what fixes it.
    func test_aNameNotInTheTreeIsAnErrorNamingWhatIsThere() throws {
        let output = try process(name: "missing.png", tree: try tree([("Assets.car", "car", 0o644)]))

        guard case .noValue(.error(let messageHash)) = try XCTUnwrap(output.outputValues[TreeFile.outputPort]) else {
            return XCTFail("expected an error value")
        }
        let message = try messageHash.resolveAsString()
        XCTAssertTrue(message.contains("missing.png") && message.contains("Assets.car"), message)
    }

    /// A tree that has not been produced — the tool failed — stops every file of it with
    /// the tool's reason, so the failure is reported where it happened, once.
    func test_aTreeWithoutAValuePassesItsReasonThrough() throws {
        let reason = NoValueReason.error(messageDataObjectHash: try "actool failed".intern())

        let output = try process(name: "Assets.car", tree: .noValue(reason: reason))

        guard case .noValue(.error(let messageHash)) = try XCTUnwrap(output.outputValues[TreeFile.outputPort]) else {
            return XCTFail("expected the tool's error")
        }
        XCTAssertEqual(try messageHash.resolveAsString(), "actool failed")
    }
}
