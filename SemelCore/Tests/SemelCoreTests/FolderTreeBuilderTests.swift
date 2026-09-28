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
                         files: [String: NodeValue] = [:],
                         modes: [String: NodeValue] = [:]) throws -> ProcessOutput {
        let node = try FolderTreeBuilder(thisNode: NodeRecord(id: 1, kind: FolderTreeBuilder.kind, name: nil,
                                                              properties: under.map { ["under": $0] } ?? [:],
                                                              scheduled: false, identity: nil))
        return try node.process(input: ProcessInput(inputValues: [
            FolderTreeBuilder.folderPort: ["folder": try manifest("input:/pkg/include", files: ["module.modulemap"], folders: ["nested"])],
            FolderTreeBuilder.subfoldersPort: subfolders,
            FolderTreeBuilder.filesPort: files,
            FolderTreeBuilder.fileMetadataPort: modes,
        ]))
    }

    private func metadata(_ mode: UInt16) throws -> NodeValue {
        .value(try FileMetadata(mode: mode).jsonString().intern())
    }

    private let nestedFolder = "input:/pkg/include/nested"
    private let moduleMap    = "input:/pkg/include/module.modulemap"
    private let deepHeader   = "input:/pkg/include/nested/deep.h"

    private var bothFiles: [String: NodeValue] {
        get throws {
            [moduleMap: .value(try "module CAtomic {}".intern()), deepHeader: .value(try "// h".intern())]
        }
    }

    private func tree(of output: ProcessOutput) throws -> TreeManifest {
        let json = try XCTUnwrap(output.outputValues[FolderTreeBuilder.outputPort]).expectValue().resolveAsString()
        return try TypeRegistry.decodeAndCast(encodedJSON: json)
    }

    func test_demandsEverySubfolderAndFileBeforeProducingTheTree() throws {
        let output = try process()

        XCTAssertEqual(output.inputWireSpecs[FolderTreeBuilder.subfoldersPort]?.keys.sorted(), [nestedFolder])
        XCTAssertEqual(output.inputWireSpecs[FolderTreeBuilder.filesPort]?.keys.sorted(), [moduleMap])
        guard case .noValue(.pending) = try XCTUnwrap(output.outputValues[FolderTreeBuilder.outputPort]) else {
            return XCTFail("pending until the walk is done")
        }
    }

    func test_everyFileLandsUnderThePrefixWithItsPathRelativeToTheFolder() throws {
        let output = try process(
            under: "CAtomic",
            subfolders: [nestedFolder: try manifest(nestedFolder, files: ["deep.h"])],
            files: try bothFiles,
            modes: [moduleMap: try metadata(0o644), deepHeader: try metadata(0o644)])

        XCTAssertEqual(try tree(of: output).entries.map(\.path), ["CAtomic/module.modulemap", "CAtomic/nested/deep.h"])
    }

    // MARK: - Modes (B-108)

    /// Each file's mode is demanded from the file itself, beside its bytes.
    func test_demandsEachFilesModeFromTheFile() throws {
        let output = try process(subfolders: [nestedFolder: try manifest(nestedFolder, files: ["deep.h"])])

        let modeSpecs = try XCTUnwrap(output.inputWireSpecs[FolderTreeBuilder.fileMetadataPort])
        XCTAssertEqual(modeSpecs.keys.sorted(), [moduleMap, deepHeader])
        XCTAssertEqual(modeSpecs[deepHeader], GraphSpecNode.staticFile(at: deepHeader).port(FileMetadata.portName))
    }

    /// A tree built before a file's mode arrived would publish the default and then change:
    /// the walk waits for the modes as it waits for the bytes.
    func test_theTreeWaitsForEveryFilesMode() throws {
        let output = try process(subfolders: [nestedFolder: try manifest(nestedFolder, files: ["deep.h"])],
                                 files: try bothFiles,
                                 modes: [moduleMap: try metadata(0o644)])

        guard case .noValue(.pending) = try XCTUnwrap(output.outputValues[FolderTreeBuilder.outputPort]) else {
            return XCTFail("pending until every mode has arrived")
        }
    }

    func test_eachEntryCarriesTheModeTheFileWasPushedWith() throws {
        let output = try process(subfolders: [nestedFolder: try manifest(nestedFolder, files: ["deep.h"])],
                                 files: try bothFiles,
                                 modes: [moduleMap: try metadata(0o644), deepHeader: try metadata(0o755)])

        let built = try tree(of: output)
        XCTAssertEqual(built.entry(at: "module.modulemap")?.mode, 0o644)
        XCTAssertEqual(built.entry(at: "nested/deep.h")?.mode, 0o755)
    }
}
