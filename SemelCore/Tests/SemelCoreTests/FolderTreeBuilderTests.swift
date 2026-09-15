//
//  FolderTreeBuilderTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// A folder as a tree: walked one level per pass, every file with its path relative to
/// the folder, under a prefix when one is given.
final class FolderTreeBuilderTests: SemelCoreTestCase {

    private func manifest(_ path: String, files: [String] = [], folders: [String] = []) throws -> NodeValue {
        let entries = files.map { FolderManifestEntry(name: $0, isFolder: false, isPinned: true) }
                    + folders.map { FolderManifestEntry(name: $0, isFolder: true, isPinned: true) }
        return .value(try FolderManifest(baseFolderPath: path, entries: entries).toJSON().intern())
    }

    private func process(under: String? = nil,
                         subfolders: [String: NodeValue] = [:],
                         files: [String: NodeValue] = [:]) throws -> ProcessOutput {
        let node = try FolderTreeBuilder(thisNode: NodeRecord(id: 1, kind: FolderTreeBuilder.kind, name: nil,
                                                              properties: under.map { ["under": $0] } ?? [:],
                                                              scheduled: false, graphSpec: nil))
        return try node.process(input: ProcessInput(inputValues: [
            FolderTreeBuilder.folderPort: ["folder": try manifest("input:/pkg/include", files: ["module.modulemap"], folders: ["nested"])],
            FolderTreeBuilder.subfoldersPort: subfolders,
            FolderTreeBuilder.filesPort: files,
        ]))
    }

    func test_demandsEverySubfolderAndFileBeforeProducingTheTree() throws {
        let output = try process()

        XCTAssertEqual(output.inputWireSpecs[FolderTreeBuilder.subfoldersPort]?.keys.sorted(), ["input:/pkg/include/nested"])
        XCTAssertEqual(output.inputWireSpecs[FolderTreeBuilder.filesPort]?.keys.sorted(), ["input:/pkg/include/module.modulemap"])
        guard case .noValue(.pending) = try XCTUnwrap(output.outputValues[FolderTreeBuilder.outputPort]) else {
            return XCTFail("pending until the walk is done")
        }
    }

    func test_everyFileLandsUnderThePrefixWithItsPathRelativeToTheFolder() throws {
        let output = try process(
            under: "CAtomic",
            subfolders: ["input:/pkg/include/nested": try manifest("input:/pkg/include/nested", files: ["deep.h"])],
            files: ["input:/pkg/include/module.modulemap": .value(try "module CAtomic {}".intern()),
                    "input:/pkg/include/nested/deep.h": .value(try "// h".intern())])

        let json = try XCTUnwrap(output.outputValues[FolderTreeBuilder.outputPort]).expectValue().resolveAsString()
        let tree: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: json)
        XCTAssertEqual(tree.entries.map(\.path), ["CAtomic/module.modulemap", "CAtomic/nested/deep.h"])
    }
}
