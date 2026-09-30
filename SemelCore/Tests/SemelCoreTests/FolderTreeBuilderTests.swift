//
//  FolderTreeBuilderTests.swift
//  SemelCore
//

@testable import SemelCore
import SemelNodeKit
import XCTest

/// A folder as a tree: read from its subtree manifest (B-135), every file with its path
/// relative to the folder, under a prefix when one is given.
final class FolderTreeBuilderTests: SemelCoreTestCase {

    private func entries(files: [String] = [], folders: [String] = []) -> [FolderManifestEntry] {
        files.map { FolderManifestEntry(name: $0, isFolder: false, isPinned: true) }
            + folders.map { FolderManifestEntry(name: $0, isFolder: true, isPinned: true) }
    }

    private let rootFolder = "input:/pkg/include"

    /// With `subfolders`, the listings of the folders below the root by path, the root's
    /// tree has arrived, folded from them; without, the run is the first.
    private func process(under: String? = nil,
                         subfolders: [String: [FolderManifestEntry]]? = nil,
                         files: [String: NodeValue] = [:],
                         modes: [String: NodeValue] = [:]) throws -> ProcessOutput {
        let node = try FolderTreeBuilder(thisNode: NodeRecord(id: 1, kind: FolderTreeBuilder.kind, name: nil,
                                                              properties: under.map { ["under": $0] } ?? [:],
                                                              scheduled: false, identity: nil))
        let root = entries(files: ["module.modulemap"], folders: ["nested"])
        var trees: [String: NodeValue] = [:]
        if let subfolders {
            let listings = subfolders.merging([rootFolder: root]) { first, _ in first }
            trees[rootFolder] = .value(try FolderSubtreeManifest.folding(at: rootFolder, listings: listings).toJSON().intern())
        }
        return try node.process(input: ProcessInput(inputValues: [
            FolderTreeBuilder.folderPort: ["folder": .value(try FolderManifest(baseFolderPath: rootFolder, entries: root).toJSON().intern())],
            FolderTreeBuilder.folderTreePort: trees,
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

    func test_demandsTheFoldersTreeAndItsFilesBeforeProducingTheTree() throws {
        let output = try process()

        XCTAssertEqual(output.inputWireSpecs[FolderTreeBuilder.folderTreePort]?.rendered,
                       [rootFolder: "Folder(path: '\(rootFolder)').subtreeManifest"])
        XCTAssertEqual(output.inputWireSpecs[FolderTreeBuilder.filesPort]?.keys.sorted(), [moduleMap])
        guard case .noValue(.pending) = try XCTUnwrap(output.outputValues[FolderTreeBuilder.outputPort]) else {
            return XCTFail("pending until the tree and the files are in")
        }
    }

    /// Once the tree is in, the files of every folder below are demanded at once.
    func test_demandsEveryFileOfTheTreeOnceItHasArrived() throws {
        let output = try process(subfolders: [nestedFolder: entries(files: ["deep.h"])])

        XCTAssertEqual(output.inputWireSpecs[FolderTreeBuilder.filesPort]?.keys.sorted(), [moduleMap, deepHeader])
        XCTAssertEqual(output.inputWireSpecs[FolderTreeBuilder.folderTreePort]?.keys.sorted(), [rootFolder])
    }

    func test_everyFileLandsUnderThePrefixWithItsPathRelativeToTheFolder() throws {
        let output = try process(
            under: "CAtomic",
            subfolders: [nestedFolder: entries(files: ["deep.h"])],
            files: try bothFiles,
            modes: [moduleMap: try metadata(0o644), deepHeader: try metadata(0o644)])

        XCTAssertEqual(try tree(of: output).entries.map(\.path), ["CAtomic/module.modulemap", "CAtomic/nested/deep.h"])
    }

    // MARK: - Modes (B-108)

    /// Each file's mode is demanded from the file itself, beside its bytes.
    func test_demandsEachFilesModeFromTheFile() throws {
        let output = try process(subfolders: [nestedFolder: entries(files: ["deep.h"])])

        let modeSpecs = try XCTUnwrap(output.inputWireSpecs[FolderTreeBuilder.fileMetadataPort])
        XCTAssertEqual(modeSpecs.keys.sorted(), [moduleMap, deepHeader])
        XCTAssertEqual(modeSpecs[deepHeader], GraphSpecNode.staticFile(at: deepHeader).port(FileMetadata.portName))
    }

    /// A tree built before a file's mode arrived would publish the default and then change:
    /// the node waits for the modes as it waits for the bytes.
    func test_theTreeWaitsForEveryFilesMode() throws {
        let output = try process(subfolders: [nestedFolder: entries(files: ["deep.h"])],
                                 files: try bothFiles,
                                 modes: [moduleMap: try metadata(0o644)])

        guard case .noValue(.pending) = try XCTUnwrap(output.outputValues[FolderTreeBuilder.outputPort]) else {
            return XCTFail("pending until every mode has arrived")
        }
    }

    func test_eachEntryCarriesTheModeTheFileWasPushedWith() throws {
        let output = try process(subfolders: [nestedFolder: entries(files: ["deep.h"])],
                                 files: try bothFiles,
                                 modes: [moduleMap: try metadata(0o644), deepHeader: try metadata(0o755)])

        let built = try tree(of: output)
        XCTAssertEqual(built.entry(at: "module.modulemap")?.mode, 0o644)
        XCTAssertEqual(built.entry(at: "nested/deep.h")?.mode, 0o755)
    }

    // MARK: - Links (B-77)

    /// A folder whose listing names a subfolder as a link is not read into — what the link
    /// names is read where it is — and the tree holds the link; a file pushed as a link is a
    /// link entry, its target being in the tree.
    func test_aFolderLinkIsPlacedAndNotReadIntoAndAFileLinkIsALink() throws {
        let node = try FolderTreeBuilder(thisNode: NodeRecord(id: 1, kind: FolderTreeBuilder.kind))
        let framework = "input:/fw/Tiny.framework"
        let listings: [String: [FolderManifestEntry]] = [
            framework: [FolderManifestEntry(name: "Versions", isFolder: true, isPinned: true),
                        FolderManifestEntry(name: "Headers", isFolder: true, isPinned: true, symbolicLinkTarget: "Versions/Current/Headers"),
                        FolderManifestEntry(name: "Tiny", isFolder: false, isPinned: true)],
            "\(framework)/Versions":           [FolderManifestEntry(name: "A", isFolder: true, isPinned: true),
                                                FolderManifestEntry(name: "Current", isFolder: true, isPinned: true, symbolicLinkTarget: "A")],
            "\(framework)/Versions/A":         [FolderManifestEntry(name: "Tiny", isFolder: false, isPinned: true),
                                                FolderManifestEntry(name: "Headers", isFolder: true, isPinned: true)],
            "\(framework)/Versions/A/Headers": [FolderManifestEntry(name: "Tiny.h", isFolder: false, isPinned: true)],
            // What the links hold, pushed where they stand as a push stores them; never read.
            "\(framework)/Headers":            [FolderManifestEntry(name: "Tiny.h", isFolder: false, isPinned: true)],
            "\(framework)/Versions/Current":   [FolderManifestEntry(name: "Tiny", isFolder: false, isPinned: true)],
        ]
        let rootManifest = FolderManifest(baseFolderPath: framework, entries: try XCTUnwrap(listings[framework]))
        let link = try FileMetadata(mode: 0o755, symbolicLinkTarget: "Versions/Current/Tiny").jsonString().intern()
        let output = try node.process(input: ProcessInput(inputValues: [
            FolderTreeBuilder.folderPort:       ["folder": .value(try rootManifest.toJSON().intern())],
            FolderTreeBuilder.folderTreePort:   [framework: .value(try FolderSubtreeManifest.folding(at: framework, listings: listings)
                                                                        .toJSON().intern())],
            FolderTreeBuilder.filesPort:        ["\(framework)/Tiny":                     .value(try "binary".intern()),
                                                 "\(framework)/Versions/A/Tiny":          .value(try "binary".intern()),
                                                 "\(framework)/Versions/A/Headers/Tiny.h": .value(try "header".intern())],
            FolderTreeBuilder.fileMetadataPort: ["\(framework)/Tiny":                     .value(link),
                                                 "\(framework)/Versions/A/Tiny":          try metadata(0o755),
                                                 "\(framework)/Versions/A/Headers/Tiny.h": try metadata(0o644)],
        ]))

        XCTAssertEqual(output.inputWireSpecs[FolderTreeBuilder.filesPort]?.keys.sorted(),
                       ["\(framework)/Tiny", "\(framework)/Versions/A/Headers/Tiny.h", "\(framework)/Versions/A/Tiny"],
                       "nothing below a folder link is asked for")
        XCTAssertEqual(try tree(of: output).entries, [
            TreeManifestEntry(path: "Headers", symbolicLinkTarget: "Versions/Current/Headers"),
            TreeManifestEntry(path: "Tiny", symbolicLinkTarget: "Versions/Current/Tiny"),
            TreeManifestEntry(path: "Versions/A/Headers/Tiny.h", hash: try "header".intern(), mode: 0o644),
            TreeManifestEntry(path: "Versions/A/Tiny", hash: try "binary".intern(), mode: 0o755),
            TreeManifestEntry(path: "Versions/Current", symbolicLinkTarget: "A"),
        ])
    }
}
