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

    // MARK: - Modes (B-108)

    /// The mode on a file's `fileMetadata` wire is the entry's; a file with no such wire —
    /// a plist builder publishes none — has the default.
    func test_eachEntryCarriesTheModeWiredBesideItsFile() throws {
        let node = try TreeBuilder(thisNode: NodeRecord(id: 1, kind: TreeBuilder.kind))
        let executable = try FileMetadata(mode: FileMetadata.executableMode).jsonString().intern()
        let output = try node.process(input: ProcessInput(inputValues: [
            TreeBuilder.inputPort:             ["Hello": .value(try "binary".intern()),
                                                "Info.plist": .value(try "plist".intern())],
            TreeBuilder.fileMetadataInputPort: ["Hello": .value(executable)],
        ]))

        let json = try XCTUnwrap(output.outputValues[TreeBuilder.outputPort]).expectValue().resolveAsString()
        let manifest: TreeManifest = try TypeRegistry.decodeAndCast(encodedJSON: json)
        XCTAssertEqual(manifest.entry(at: "Hello")?.mode, 0o755)
        XCTAssertEqual(manifest.entry(at: "Info.plist")?.mode, 0o644)
    }

    /// A formula names the files only; the modes are wired where the spec is built, from
    /// every source that publishes one and is read at the file it describes.
    func test_aSpecGainsAModeWireForEachFileWhoseSourcePublishesOne() throws {
        let tree = GraphSpecNode(TreeBuilder.self, inputs: [TreeBuilder.inputPort: [
            "PkgInfo":    .staticFile(at: "input:/app/PkgInfo"),
            "Info.plist": GraphSpecNode(SampleTool.self).port(SampleTool.output),
            "notes":      GraphSpecNode(TreeFile.self, properties: [TreeFile.nameProperty: "notes"],
                                        inputs: [TreeFile.treeInputPort: ["tree": .staticFile(at: "input:/tree")]])
                              .port(TreeFile.outputPort),
            "log":        GraphSpecNode(TreeFile.self, properties: [TreeFile.nameProperty: "log"],
                                        inputs: [TreeFile.treeInputPort: ["tree": .staticFile(at: "input:/tree")]])
                              .port(FileMetadata.portName),
        ]]).wiringFileMetadata()

        let modes = try XCTUnwrap(tree.inputs.first { $0.portName == TreeBuilder.fileMetadataInputPort })
        XCTAssertEqual(modes.wires.map(\.name), ["PkgInfo", "notes"],
                       "a source with no fileMetadata port, and a wire not read at the file, have none")
        XCTAssertEqual(modes.wires.map(\.node.outputPort), [FileMetadata.portName, FileMetadata.portName])
        let pkgInfo = try XCTUnwrap(tree.inputs.first { $0.portName == TreeBuilder.inputPort }?.wires.first { $0.name == "PkgInfo" })
        XCTAssertEqual(modes.wires[0].node, pkgInfo.node.port(FileMetadata.portName),
                       "the mode comes from the node the file does")
    }

    /// A spec that already wires the modes is taken as it stands.
    func test_aModeWireTheSpecStatesIsLeftAlone() throws {
        let stated = GraphSpecNode(TreeBuilder.self, inputs: [
            TreeBuilder.inputPort:             ["PkgInfo": .staticFile(at: "input:/app/PkgInfo")],
            TreeBuilder.fileMetadataInputPort: ["PkgInfo": GraphSpecNode.settingsLiteral(["mode": "493"])],
        ])

        XCTAssertEqual(stated.wiringFileMetadata(), stated)
    }
}
