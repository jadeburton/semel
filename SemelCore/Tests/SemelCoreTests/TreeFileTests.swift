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
                              properties: [TreeFile.nameProperty: name], scheduled: false, identity: nil)
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

    /// B-77. A link entry is put on the ports as a pushed link is: the target on
    /// `fileMetadata`, which a product and the export read, and on `output` what it names
    /// in the tree — the file's bytes with its mode, or the empty file for a folder.
    func test_aLinkEntryCarriesItsTargetAndWhatItNames() throws {
        let tree = TreeManifest(entries: [
            TreeManifestEntry(path: "F/Versions/A/Tiny", hash: try "binary".intern(), mode: 0o755),
            TreeManifestEntry(path: "F/Versions/Current", symbolicLinkTarget: "A"),
            TreeManifestEntry(path: "F/Tiny", symbolicLinkTarget: "Versions/Current/Tiny"),
        ])
        let value = NodeValue.value(try tree.toJSON().intern())

        let fileLink = try process(name: "F/Tiny", tree: value)
        XCTAssertEqual(try fileLink.outputValues[TreeFile.outputPort]?.expectValue().resolveAsString(), "binary")
        let fileMetadata = try XCTUnwrap(fileLink.outputValues[FileMetadata.portName]).expectValue().resolveAsString()
        XCTAssertEqual(FileMetadata.decode(from: fileMetadata), FileMetadata(mode: 0o755, symbolicLinkTarget: "Versions/Current/Tiny"))

        let folderLink = try process(name: "F/Versions/Current", tree: value)
        XCTAssertEqual(try folderLink.outputValues[TreeFile.outputPort]?.expectValue(), "")
        let folderMetadata = try XCTUnwrap(folderLink.outputValues[FileMetadata.portName]).expectValue().resolveAsString()
        XCTAssertEqual(FileMetadata.decode(from: folderMetadata), FileMetadata(symbolicLinkTarget: "A"))
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

    /// A tree that failed stops every file of it, and each says so as its own state rather
    /// than repeating the tool's sentence, so the failure is reported where it happened,
    /// once, with the files counted under it.
    func test_aTreeWithoutAValueStopsEveryFileAsACarriedState() throws {
        let node = try TreeFile(thisNode: NodeRecord(id: 1, kind: TreeFile.kind,
                                                     properties: [TreeFile.nameProperty: "Assets.car"]))
        let output = node.processWithCatch(input: ProcessInput(inputValues: [TreeFile.treeInputPort: [
            "tree": .noValue(reason: try .failure("actool failed")),
        ]]))

        for port in [TreeFile.outputPort, TreeFile.fileMetadataOutputPort] {
            guard case .noValue(.inputInError) = try XCTUnwrap(output.outputValues[port]) else {
                return XCTFail("expected the carried state on \(port)")
            }
        }
    }
}
